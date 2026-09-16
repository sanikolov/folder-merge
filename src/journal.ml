type t = { channel : out_channel; path : string; mutable records : int }

let create path =
  {
    channel = open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 path;
    path;
    records = 0;
  }

let path t = t.path

(* Bounded record reader. Only a torn final record is ignored; malformed complete
   records fail. The returned offset is safe to append after recovery preflight. *)
let iter path f =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let chunk = Bytes.create 65536 and line = Buffer.create 4096 in
      let offset = ref 0L and complete = ref 0L and running = ref true in
      while !running do
        let n = input channel chunk 0 (Bytes.length chunk) in
        if n = 0 then running := false
        else
          for i = 0 to n - 1 do
            offset := Int64.succ !offset;
            if Bytes.get chunk i = '\n' then begin
              f (Yojson.Safe.from_string (Buffer.contents line));
              Buffer.clear line;
              complete := !offset
            end
            else begin
              if Buffer.length line >= 1048576 then failwith "Transaction log record exceeds 1 MiB";
              Buffer.add_char line (Bytes.get chunk i)
            end
          done
      done;
      !complete)

let append path ~complete =
  let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.LargeFile.ftruncate fd complete;
      Win.flush fd);
  { channel = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path; path; records = 0 }

let first path =
  let exception Found of Yojson.Safe.t in
  try
    ignore (iter path (fun json -> raise (Found json)));
    failwith "Transaction log has no complete header"
  with Found json -> json

let emit t event fields =
  if t.records mod 256 = 0 && Win.free_space (Filename.dirname t.path) < 67108864L then
    failwith "Journal volume has less than 64 MiB available";
  t.records <- t.records + 1;
  let json =
    `Assoc (("time", `Float (Unix.gettimeofday ())) :: ("event", `String event) :: fields)
  in
  Yojson.Safe.to_channel t.channel json;
  output_char t.channel '\n';
  flush t.channel;
  if event <> "PLANNED" then Win.flush (Unix.descr_of_out_channel t.channel)

let close t = close_out t.channel
let s x = `String x

let error t phase path exn =
  emit t "ERROR" [ ("phase", s phase); ("path", s path); ("message", s (Printexc.to_string exn)) ]
