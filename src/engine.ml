open Model

let check_sources db journal c ~run_id =
  let errors = ref 0 in
  Planner.iter db (fun p ->
      let source = Path.join c.trim p.source in
      try
        Win.probe source Win.Remove_file;
        let temporary =
          Path.join (Filename.dirname p.destination)
            (".folder-merge-" ^ run_id ^ "-" ^ p.id ^ ".tmp")
        in
        if Win.exists temporary then failwith ("Temporary destination already exists: " ^ temporary)
      with e ->
        incr errors;
        Journal.error journal "SOURCE_PREFLIGHT" source e);
  (* Only ancestors of affected sources can become newly empty. Existing empty
     directories and the T root are preserved. rmdir itself confirms emptiness. *)
  if c.empty_dirs = Prune then
    Db.iter db "SELECT rel FROM prune_dirs" [||] (fun r ->
        try Win.probe (Path.join c.trim r.(0)) Win.Remove_directory
        with e ->
          incr errors;
          Journal.error journal "PRUNE_PREFLIGHT" r.(0) e);
  if !errors > 0 then failwith (Printf.sprintf "%d preflight failures; no files moved" !errors)

let prepare_directories db journal =
  try
    Db.iter db "SELECT path FROM parents ORDER BY depth,path" [||] (fun r ->
        Journal.emit journal "MKDIR_INTENT" [ ("path", Journal.s r.(0)) ];
        Win.mkdir r.(0);
        Db.run db "UPDATE parents SET created=1 WHERE path=?" [| r.(0) |];
        Journal.emit journal "CREATE_DIRECTORY"
          [ ("path", Journal.s r.(0)); ("identity", Journal.s (Win.identity r.(0))) ]);
    (* Actual creation probes validate inherited ACLs before moving any file. *)
    Db.iter db "SELECT path FROM destination_dirs" [||] (fun r -> Win.probe_create r.(0))
  with e ->
    Db.iter db "SELECT path FROM parents WHERE created=1 ORDER BY depth DESC,path DESC" [||]
      (fun r ->
        try ignore (Win.remove_dir r.(0))
        with cleanup -> Journal.error journal "PREFLIGHT_CLEANUP" r.(0) cleanup);
    raise e

let execute db journal c run_id =
  prepare_directories db journal;
  Planner.iter db (fun p ->
      let source = Path.join c.trim p.source in
      let parent = Filename.dirname p.destination in
      let temporary = Path.join parent (".folder-merge-" ^ run_id ^ "-" ^ p.id ^ ".tmp") in
      Journal.emit journal "BEGIN_MOVE"
        (Planner.fields p
        @ [
            ("source_identity", Journal.s (Win.identity source)); ("temporary", Journal.s temporary);
          ]);
      let io =
        Transfer.
          {
            rename = Win.rename;
            copy =
              (fun src dst ->
                Space.check parent (Win.required_space src parent);
                Win.copy src dst);
            digest = Win.hash;
            size =
              (fun path ->
                match Win.attributes path with Some m -> m.size | None -> failwith "Missing file");
            remove = Win.unlink;
            exists = Win.exists;
            checkpoint =
              (fun event ->
                let fields = Planner.fields p in
                let fields =
                  if event = "COPIED" then
                    ("copy_identity", Journal.s (Win.identity temporary)) :: fields
                  else fields
                in
                Journal.emit journal event fields);
          }
      in
      try
        Space.check parent 65536L;
        Transfer.move io c.verification ~source ~destination:p.destination ~temporary;
        Db.run db "UPDATE plan SET status='done' WHERE id=?" [| p.id |];
        Planner.record journal "DONE" p
      with e ->
        Journal.error journal "TRANSFER" source e;
        raise e);
  if c.empty_dirs = Prune then
    Db.iter db "SELECT rel FROM prune_dirs ORDER BY length(rel) DESC,rel DESC" [||] (fun r ->
        let path = Path.join c.trim r.(0) in
        Journal.emit journal "PRUNE_INTENT" [ ("path", Journal.s path) ];
        if Win.remove_dir path then Journal.emit journal "PRUNE" [ ("path", Journal.s path) ])

let run c argv =
  let c =
    try
      let c = Path.validate c in
      { c with log = Path.new_log c }
    with Invalid_argument message | Failure message ->
      raise (Config.Error ("Invalid folder parameters: " ^ message))
  in
  let temp = Win.canonical (Filename.get_temp_dir_name ()) in
  Path.ensure_outside [| c.keep; c.trim; c.quarantine |] temp;
  Space.check temp 0L;
  let state = Filename.temp_file ~temp_dir:temp "folder-merge-" ".sqlite" in
  let id = Filename.remove_extension (Filename.basename state) in
  Space.check (Filename.dirname c.log) 0L;
  let journal = Journal.create c.log in
  Printf.printf "Journal: %s\n%!" (Journal.path journal);
  let success = ref false in
  Fun.protect
    ~finally:(fun () ->
      Journal.close journal;
      if !success then Sys.remove state)
    (fun () ->
      Journal.emit journal "START"
        [
          ("run_id", Journal.s id);
          ("format", Journal.s "filemerge-transaction");
          ("version", `Int 1);
          ("keep", Journal.s c.keep);
          ("trim", Journal.s c.trim);
          ("quarantine", Journal.s c.quarantine);
          ("keep_identity", Journal.s (Win.identity c.keep));
          ("trim_identity", Journal.s (Win.identity c.trim));
          ( "quarantine_identity",
            Journal.s (if Win.exists c.quarantine then Win.identity c.quarantine else "") );
          ("operation", Journal.s (operation_name c.operation));
          ("argv", `List (Array.to_list (Array.map Journal.s argv)));
        ];
      let db = Db.open_db state in
      Fun.protect
        ~finally:(fun () -> Db.close db)
        (fun () ->
          try
            Db.schema db;
            Printf.printf "Scanning and checking access...\n%!";
            let errors_k = Db.transaction db (fun () -> Scan.run db journal c Keeper) in
            let errors_t = Db.transaction db (fun () -> Scan.run db journal c Incoming) in
            if errors_k + errors_t > 0 then
              failwith
                (Printf.sprintf "%d scan/access failures; execution refused" (errors_k + errors_t));
            Printf.printf "Hashing shared-size candidates...\n%!";
            Pool.with_pool c.parallelism (fun pool ->
                let errors = Db.transaction db (fun () -> Scan.hash_candidates db journal c pool) in
                Journal.emit journal "IO_PEAK"
                  [ ("hash_jobs", `Int (Pool.peak pool)); ("global_limit", `Int c.parallelism) ];
                if errors > 0 then
                  failwith (Printf.sprintf "%d hash failures; execution refused" errors));
            Db.iter db
              "SELECT tree,count(hash),coalesce(sum(CASE WHEN hash IS NOT NULL THEN size ELSE 0 \
               END),0) FROM files GROUP BY tree"
              [||] (fun r ->
                Journal.emit journal "HASH_TOTAL"
                  [
                    ("tree", Journal.s r.(0)); ("files", Journal.s r.(1)); ("bytes", Journal.s r.(2));
                  ]);
            Printf.printf "Planning destinations and checking space...\n%!";
            Db.transaction db (fun () -> Planner.build db journal c);
            Planner.summary db journal;
            check_sources db journal c ~run_id:id;
            Space.preflight db journal c;
            if c.operation <> Plan then execute db journal c id;
            Journal.emit journal "END"
              [
                ("outcome", Journal.s (if c.operation = Plan then "PLANNED" else "SUCCESS"));
                ("scan_hash_errors", `Int 0);
              ];
            success := true
          with e ->
            Journal.error journal "RUN" "" e;
            Journal.emit journal "END"
              [ ("outcome", Journal.s "FAILED"); ("retained_manifest", Journal.s state) ];
            raise e))
