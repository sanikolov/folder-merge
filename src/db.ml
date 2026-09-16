type handle
type statement
type cached = { statement : statement; mutable in_use : bool }

type t = {
  handle : handle;
  directory : string;
  mutable writes : int;
  statements : (string, cached) Hashtbl.t;
}

external native_open : string -> handle = "fm_db_open"
external native_close : handle -> unit = "fm_db_close"
external native_exec : handle -> string -> unit = "fm_db_exec"
external native_prepare : handle -> string -> statement = "fm_db_prepare"
external finalize : statement -> unit = "fm_db_finalize"
external reset : statement -> string array -> unit = "fm_db_reset"
external bind_blob : statement -> int -> string -> unit = "fm_db_bind_blob"
external step : statement -> string array option = "fm_db_step"

let open_db path =
  {
    handle = native_open path;
    directory = Filename.dirname path;
    writes = 0;
    statements = Hashtbl.create 64;
  }

let close db =
  Hashtbl.iter (fun _ c -> finalize c.statement) db.statements;
  native_close db.handle

let check_space db =
  if Win.free_space db.directory < 67108864L then
    failwith "Run-state volume has less than 64 MiB available"

let exec db sql =
  check_space db;
  native_exec db.handle sql

let prepare db sql = native_prepare db.handle sql

let with_statement db sql f =
  let cached =
    match Hashtbl.find_opt db.statements sql with
    | Some c when not c.in_use -> Some c
    | None when Hashtbl.length db.statements < 64 ->
        let c = { statement = prepare db sql; in_use = false } in
        Hashtbl.add db.statements sql c;
        Some c
    | _ -> None
  in
  match cached with
  | Some c ->
      c.in_use <- true;
      Fun.protect
        ~finally:(fun () ->
          reset c.statement [||];
          c.in_use <- false)
        (fun () -> f c.statement)
  | None ->
      let s = prepare db sql in
      Fun.protect ~finally:(fun () -> finalize s) (fun () -> f s)

let run db sql args =
  if db.writes mod 256 = 0 then check_space db;
  db.writes <- db.writes + 1;
  with_statement db sql (fun s ->
      reset s args;
      ignore (step s))

let one db sql args =
  with_statement db sql (fun s ->
      reset s args;
      step s)

let update_digest db ~id ~digest =
  if String.length digest <> 32 then invalid_arg "SHA-256 must contain 32 bytes";
  if db.writes mod 256 = 0 then check_space db;
  db.writes <- db.writes + 1;
  with_statement db "UPDATE files SET hash=? WHERE id=?" (fun s ->
      reset s [| ""; id |];
      bind_blob s 1 digest;
      ignore (step s))

let iter db sql args f =
  with_statement db sql (fun s ->
      reset s args;
      let running = ref true in
      while !running do
        match step s with None -> running := false | Some row -> f row
      done)

let transaction db f =
  exec db "BEGIN";
  try
    let result = f () in
    exec db "COMMIT";
    result
  with e ->
    (try native_exec db.handle "ROLLBACK" with _ -> ());
    raise e

let schema db =
  exec db
    {|
 PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;
 PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
 CREATE TABLE dirs(id INTEGER PRIMARY KEY,tree TEXT,rel TEXT,identity TEXT,done INTEGER DEFAULT 0,
   UNIQUE(tree,identity));
 CREATE INDEX pending_dirs ON dirs(tree,done,id);
 CREATE TABLE files(id INTEGER PRIMARY KEY,tree TEXT,rel TEXT,size INTEGER,hash BLOB,
   UNIQUE(tree,rel));
 CREATE INDEX sizes ON files(tree,size);
 CREATE INDEX contents ON files(tree,size,hash,rel);
 CREATE TABLE reservations(path TEXT PRIMARY KEY,kind TEXT);
 CREATE TABLE parents(path TEXT PRIMARY KEY,depth INTEGER,created INTEGER DEFAULT 0);
 CREATE TABLE destination_dirs(path TEXT PRIMARY KEY);
 CREATE TABLE prune_dirs(rel TEXT PRIMARY KEY);
 CREATE TABLE plan(id INTEGER PRIMARY KEY,rel TEXT,dest TEXT,action TEXT,size INTEGER,
   witness TEXT,renamed INTEGER,status TEXT DEFAULT 'pending');
 CREATE TABLE space(volume TEXT PRIMARY KEY,base TEXT,bytes INTEGER);
 |}
