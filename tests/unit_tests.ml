open Model

let checks = ref 0

let check name yes =
  incr checks;
  if not yes then failwith name

let raises name f =
  check name
    (try
       f ();
       false
     with _ -> true)

let test_collision () =
  List.iter
    (fun (name, expected) -> check name (Collision.suffix name 2 = expected))
    [
      ("report.pdf", "report (2).pdf");
      ("a.b.c", "a.b (2).c");
      ("README", "README (2)");
      (".gitignore", ".gitignore (2)");
      ("résumé.txt", "résumé (2).txt");
    ]

let test_cli () =
  let args =
    [|
      "filemerge";
      "-keep";
      "K";
      "-trim";
      "T";
      "-quarantine";
      "Q";
      "-operation";
      "merge";
      "-hash";
      "sha256";
      "-parallelism";
      "8";
      "-collision";
      "rename";
      "-links";
      "skip";
      "-empty-dirs";
      "keep";
      "-verify";
      "yes";
      "-log";
      "transaction.log";
    |]
  in
  check "valid config" ((Config.parse args).parallelism = 8);
  let diagnostic argv expected =
    check ("CLI diagnostic: " ^ expected)
      (try
         ignore (Config.parse argv);
         false
       with Config.Error message -> message = expected)
  in
  diagnostic [| "filemerge" |] "No parameters supplied.";
  diagnostic [| "filemerge"; "-bogus" |] "Unknown option or unexpected argument \"-bogus\".";
  diagnostic [| "filemerge"; "-keep" |] "Missing value for -keep.";
  diagnostic [| "filemerge"; "-keep"; "-trim"; "T" |] "Missing value for -keep.";
  diagnostic [| "filemerge"; "-keep"; "" |] "Empty value for -keep.";
  diagnostic
    [| "filemerge"; "-keep"; "K"; "-keep"; "other" |]
    "Option -keep was supplied more than once.";
  check "recovery command"
    (Config.command [| "filemerge"; "-recover"; "transaction.log" |] = Recover "transaction.log");
  raises "missing recovery log" (fun () -> ignore (Config.command [| "filemerge"; "-recover" |]));
  raises "mixed recovery command" (fun () ->
      ignore (Config.command (Array.append args [| "-recover"; "transaction.log" |])));
  for i = 0 to 10 do
    let missing = Array.init 21 (fun j -> args.(if j < (2 * i) + 1 then j else j + 2)) in
    diagnostic missing ("Missing required option(s): " ^ args.((2 * i) + 1) ^ ".")
  done;
  List.iter
    (fun (index, value) ->
      let bad = Array.copy args in
      bad.(index) <- value;
      raises ("malformed " ^ value) (fun () -> ignore (Config.parse bad)))
    [
      (12, "0");
      (12, "9");
      (12, "-1");
      (12, "01");
      (12, "x");
      (10, "md5");
      (14, "overwrite");
      (8, "execute");
      (16, "yes");
      (18, "delete");
      (20, "true");
      (3, "-keep");
    ]

module Names = Map.Make (String)

type fault = None_ | Copy_failure | Verify_failure | Publish_failure | Checkpoint_failure

let test_transfer same_volume fault verification =
  let files = ref (Names.singleton "source" "payload") and hashes = ref 0 and events = ref [] in
  let rename src dst =
    if src = "source" && not same_volume then false
    else if src = "temp" && fault = Publish_failure then failwith "publish"
    else if Names.mem dst !files then failwith "would overwrite"
    else
      let content = Names.find src !files in
      files := Names.add dst content (Names.remove src !files);
      true
  in
  let io =
    Transfer.
      {
        rename;
        copy =
          (fun src dst ->
            files :=
              Names.add dst
                (if fault = Verify_failure then "damaged" else Names.find src !files)
                !files;
            if fault = Copy_failure then failwith "copy");
        digest =
          (fun p ->
            incr hashes;
            Names.find p !files);
        size = (fun p -> Int64.of_int (String.length (Names.find p !files)));
        exists = (fun p -> Names.mem p !files);
        remove =
          (fun p ->
            events := p :: !events;
            files := Names.remove p !files);
        checkpoint =
          (fun name ->
            if name = "DESTINATION_PUBLISHED" && fault = Checkpoint_failure then failwith "journal");
      }
  in
  let failed =
    try
      Transfer.move io verification ~source:"source" ~destination:"final" ~temporary:"temp";
      false
    with _ -> true
  in
  if fault = None_ then begin
    check "transfer succeeded"
      ((not failed) && (not (Names.mem "source" !files)) && Names.find "final" !files = "payload");
    check "rename skips verification"
      (if same_volume || verification = No_verify then !hashes = 0 else !hashes = 2)
  end
  else begin
    check "fault reported" failed;
    check "source retained" (Names.find "source" !files = "payload");
    check "no early remove" (not (List.mem "source" !events));
    check "temporary cleaned" (not (Names.mem "temp" !files))
  end

let test_existing_dest () =
  let copied = ref false and removed = ref false in
  let io =
    Transfer.
      {
        rename = (fun _ _ -> failwith "exists");
        copy = (fun _ _ -> copied := true);
        digest = (fun _ -> "");
        size = (fun _ -> 0L);
        exists = (fun _ -> false);
        remove = (fun _ -> removed := true);
        checkpoint = ignore;
      }
  in
  raises "no overwrite" (fun () ->
      Transfer.move io Verify ~source:"s" ~destination:"d" ~temporary:"tmp");
  check "rename failure doesn't copy or delete" ((not !copied) && not !removed)

let test_stack () =
  let pending = ref (Some 0) and count = ref 0 in
  Walk.drain
    ~next:(fun () ->
      let item = !pending in
      pending := None;
      item)
    ~visit:(fun depth ->
      incr count;
      if depth < 1_000_000 then pending := Some (depth + 1));
  check "million deep iterative traversal" (!count = 1_000_001)

let test_pool () =
  for n = 1 to 8 do
    Pool.with_pool n (fun pool ->
        let completed = Atomic.make 0 in
        for _ = 1 to 5 do
          Pool.run pool
            (Array.init 32 (fun _ ->
                 fun () ->
                  Unix.sleepf 0.001;
                  Atomic.incr completed))
        done;
        check "pool completion" (Atomic.get completed = 160);
        check "pool global bound" (Pool.peak pool <= n && Pool.peak pool > 0);
        raises "worker exception" (fun () -> Pool.run pool [| (fun () -> failwith "job") |]);
        Pool.run pool [| (fun () -> Atomic.incr completed) |];
        check "pool reusable after failure" (Atomic.get completed = 161))
  done

let hex s =
  String.init
    (2 * String.length s)
    (fun i -> "0123456789abcdef".[(Char.code s.[i / 2] lsr if i mod 2 = 0 then 4 else 0) land 15])

let test_native () =
  let path = Filename.temp_file "folder-merge-unit-" ".bin" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      check "empty SHA256"
        (hex (Win.hash path) = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
      let out = open_out_bin path in
      output_string out "abc";
      close_out out;
      check "abc SHA256"
        (hex (Win.hash path) = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
      let out = open_out_bin path in
      let block = String.make 1000 'a' in
      for _ = 1 to 1000 do
        output_string out block
      done;
      close_out out;
      check "million a SHA256"
        (hex (Win.hash path) = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
      Win.probe path Win.Remove_file;
      check "stream-inclusive budget" (Win.required_space path (Filename.dirname path) >= 1_000_000L);
      let copy = path ^ ".copy" in
      Fun.protect
        ~finally:(fun () ->
          Win.set_readonly path false;
          if Win.exists copy then Win.unlink copy)
        (fun () ->
          Win.set_readonly path true;
          Win.probe path Win.Remove_file;
          check "preflight leaves readonly intact" (Win.readonly path);
          Win.copy path copy;
          check "copy flush preserves readonly" (Win.readonly copy);
          check "readonly copy content" (Win.hash path = Win.hash copy);
          raises "readonly copy cannot overwrite" (fun () -> Win.copy path copy);
          check "failed copy leaves destination readonly" (Win.readonly copy);
          Win.unlink copy;
          check "readonly temporary cleanup" (not (Win.exists copy));
          check "copy leaves source readonly" (Win.readonly path)))

let test_db () =
  let p = Filename.temp_file "folder-merge-db-test-" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> Sys.remove p)
    (fun () ->
      let db = Db.open_db p in
      Fun.protect
        ~finally:(fun () -> Db.close db)
        (fun () ->
          Db.schema db;
          let digest = String.init 32 (fun i -> Char.chr (i * 19 mod 256)) in
          Db.transaction db (fun () ->
              for i = 1 to 5000 do
                Db.run db "INSERT INTO files(tree,rel,size) VALUES('K',?,1)" [| string_of_int i |];
                Db.update_digest db ~id:(string_of_int i) ~digest
              done);
          let count = ref 0 in
          Db.iter db "SELECT hash FROM files" [||] (fun r ->
              incr count;
              check "compact binary hash roundtrip" (r.(0) = digest));
          check "stream all database records" (!count = 5000);
          raises "transaction rollback" (fun () ->
              Db.transaction db (fun () ->
                  Db.exec db "DELETE FROM files";
                  failwith "rollback"));
          check "rollback keeps records"
            ((Option.get (Db.one db "SELECT count(*) FROM files" [||])).(0) = "5000")))

let () =
  test_collision ();
  test_cli ();
  test_stack ();
  test_pool ();
  test_native ();
  test_db ();
  test_transfer true None_ Verify;
  test_transfer false None_ Verify;
  test_transfer false None_ No_verify;
  List.iter
    (fun fault -> test_transfer false fault Verify)
    [ Copy_failure; Verify_failure; Publish_failure; Checkpoint_failure ];
  test_existing_dest ();
  check "low disk refusal" (not (Space.fits ~free:Space.reserve ~needed:1L));
  check "space overflow-safe" (not (Space.fits ~free:100L ~needed:Int64.max_int));
  check "space fits" (Space.fits ~free:100_000_000L ~needed:1_000_000L);
  Printf.printf "Passed %d OCaml checks\n%!" !checks
