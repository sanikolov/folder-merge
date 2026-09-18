open Model

(* The log is replayed into a temporary disk index, never a whole-run list.
   Classification is read-only; all entries must pass before undo begins. *)
type header = {
  config : config;
  run_id : string;
  keep_id : string;
  trim_id : string;
  q_id : string;
}

type decision = Restore | Remove_copy | Already_original

let decision_name = function
  | Restore -> "restore"
  | Remove_copy -> "remove_copy"
  | Already_original -> "original"

let fail message = failwith ("Recovery: " ^ message)
let member name = function `Assoc fields -> List.assoc_opt name fields | _ -> None

let string name json =
  match member name json with
  | Some (`String s) -> s
  | _ -> fail ("missing/invalid log field " ^ name)

let int64 name json =
  match member name json with
  | Some (`Int n) -> Int64.of_int n
  | Some (`Intlit s) -> Int64.of_string s
  | _ -> fail ("missing/invalid integer field " ^ name)

let id json =
  let value = string "id" json in
  if
    value = ""
    || (not (String.for_all (fun c -> c >= '0' && c <= '9') value))
    || Int64.of_string value <= 0L
  then fail "invalid operation id";
  value

let same a b = Win.key a = Win.key b

let clean_components path =
  if
    String.contains path '\000'
    || List.exists
         (fun s -> s = "." || s = "..")
         (String.split_on_char '\\' (String.map (fun c -> if c = '/' then '\\' else c) path))
  then fail ("unsafe path in log: " ^ path)

let inside root path =
  clean_components path;
  if (not (Path.contains ~parent:root path)) || same root path then
    fail ("path outside expected tree: " ^ path)

let source h relative =
  clean_components relative;
  if (not (Filename.is_relative relative)) || String.contains relative ':' then
    fail "invalid relative source path";
  let path = Path.join h.config.trim relative in
  inside h.config.trim path;
  path

let no_links root path =
  (* Reject substitution of any component by a reparse point since the run. *)
  let current = ref path in
  while Path.contains ~parent:root !current do
    (match Win.attributes !current with
    | Some m when m.reparse -> fail ("reparse point in recovery path: " ^ !current)
    | _ -> ());
    let parent = Filename.dirname !current in
    if parent = !current then fail "invalid path ancestry";
    current := parent
  done

let identity path =
  match Win.attributes path with
  | None -> None
  | Some m when m.directory || m.reparse -> fail ("expected a regular file: " ^ path)
  | Some _ -> Some (Win.identity path)

let require_size path size =
  match Win.attributes path with
  | Some m when m.size = size -> ()
  | _ -> fail ("file size has changed: " ^ path)

let equal_content a b =
  match (Win.attributes a, Win.attributes b) with
  | Some x, Some y when x.size = y.size && Win.hash a = Win.hash b -> ()
  | _ -> fail ("copies differ; preserving both: " ^ a ^ " and " ^ b)

let fields row = [ ("id", Journal.s row.(0)) ]

let schema db =
  Db.schema db;
  Db.exec db
    {|
    CREATE TABLE undo_moves(id INTEGER PRIMARY KEY,rel TEXT UNIQUE,dest TEXT,dest_key TEXT UNIQUE,size INTEGER,
      source_id TEXT,copy_id TEXT DEFAULT '',temp TEXT,undo_started INTEGER DEFAULT 0,
      undo_copy_id TEXT DEFAULT '',undo_id TEXT DEFAULT '',undo_temp TEXT DEFAULT '',decision TEXT DEFAULT '',
      source_readonly TEXT DEFAULT '');
    CREATE TABLE undo_dirs(path TEXT PRIMARY KEY,path_key TEXT UNIQUE,identity TEXT DEFAULT '');
    CREATE TABLE undo_pruned(path TEXT PRIMARY KEY);
    CREATE INDEX undo_temp_paths ON undo_moves(temp);
  |}

let header_of_json log json =
  if
    string "event" json <> "START"
    || string "format" json <> "filemerge-transaction"
    || int64 "version" json <> 1L
  then fail "unsupported transaction log format";
  let operation =
    match string "operation" json with
    | "plan" -> Plan
    | "trim" -> Trim
    | "merge" -> Merge
    | _ -> fail "invalid logged operation"
  in
  let config =
    {
      keep = string "keep" json;
      trim = string "trim" json;
      quarantine = string "quarantine" json;
      log;
      operation;
      parallelism = 1;
      links = Skip;
      empty_dirs = Keep;
      verification = Verify;
    }
  in
  let run_id = string "run_id" json in
  if
    run_id = ""
    || String.length run_id > 128
    || not
         (String.for_all
            (fun c ->
              (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || c = '-' || c = '_')
            run_id)
  then fail "invalid run identifier";
  {
    config;
    run_id;
    keep_id = string "keep_identity" json;
    trim_id = string "trim_identity" json;
    q_id = string "quarantine_identity" json;
  }

let read db log =
  let header = ref None in
  let complete =
    Journal.iter log (fun json ->
        let event = string "event" json in
        if event = "START" then begin
          if !header <> None then fail "multiple START records";
          header := Some (header_of_json log json)
        end
        else begin
          let h =
            match !header with
            | Some h -> h
            | None -> fail "START must be the first complete record"
          in
          let validate_move () =
            let rel = string "source_relative_to_T" json and dest = string "destination" json in
            ignore (source h rel);
            let root =
              match string "action" json with
              | "QUARANTINE" -> h.config.quarantine
              | "MERGE" -> h.config.keep
              | _ -> fail "invalid action"
            in
            inside root dest;
            let size = int64 "bytes" json in
            if size < 0L then fail "negative file size";
            (rel, dest, Int64.to_string size)
          in
          match event with
          | "BEGIN_MOVE" ->
              if h.config.operation = Plan then fail "plan log contains a move";
              let n = id json in
              let rel, dest, size = validate_move () in
              let temp = string "temporary" json in
              let expected =
                Path.join (Filename.dirname dest) (".folder-merge-" ^ h.run_id ^ "-" ^ n ^ ".tmp")
              in
              if not (same temp expected) then fail "invalid temporary path";
              Db.run db
                "INSERT INTO undo_moves(id,rel,dest,dest_key,size,source_id,temp,source_readonly) \
                 VALUES(?,?,?,?,?,?,?,?)"
                [|
                  n;
                  rel;
                  dest;
                  Win.key dest;
                  size;
                  string "source_identity" json;
                  temp;
                  (match member "source_readonly" json with
                  | None -> "" (* Older journals did not record this attribute. *)
                  | Some (`Bool b) -> if b then "1" else "0"
                  | _ -> fail "invalid source_readonly field");
                |]
          | "COPIED" | "RENAMED" | "DESTINATION_PUBLISHED" | "SOURCE_REMOVED" | "DONE" ->
              let n = id json in
              let rel, dest, size = validate_move () in
              (match Db.one db "SELECT rel,dest,size FROM undo_moves WHERE id=?" [| n |] with
              | Some row when row.(0) = rel && row.(1) = dest && row.(2) = size -> ()
              | _ -> fail "checkpoint does not match a recorded move");
              if event = "COPIED" then
                Db.run db "UPDATE undo_moves SET copy_id=? WHERE id=?"
                  [| string "copy_identity" json; n |]
          | "MKDIR_INTENT" | "CREATE_DIRECTORY" ->
              let p = string "path" json in
              clean_components p;
              (* Q can have newly created ancestors; only those on its exact chain are allowed. *)
              if
                (not (Path.contains ~parent:h.config.keep p && not (same h.config.keep p)))
                && not
                     (Path.contains ~parent:h.config.quarantine p
                     || Path.contains ~parent:p h.config.quarantine)
              then fail "created directory outside destination trees";
              if Path.contains ~parent:p h.config.keep || Path.contains ~parent:p h.config.trim then
                fail "created directory contains an original root";
              Db.run db "INSERT OR IGNORE INTO undo_dirs(path,path_key) VALUES(?,?)"
                [| p; Win.key p |];
              if event = "CREATE_DIRECTORY" then
                Db.run db "UPDATE undo_dirs SET identity=? WHERE path=?"
                  [| string "identity" json; p |]
          | "PRUNE_INTENT" | "PRUNE" ->
              let p = string "path" json in
              inside h.config.trim p;
              Db.run db "INSERT OR IGNORE INTO undo_pruned(path) VALUES(?)" [| p |]
          | "UNDO_BEGIN" | "UNDO_COPIED" | "UNDO_PUBLISHED" | "UNDO_DONE" ->
              let n = id json in
              if Db.one db "SELECT id FROM undo_moves WHERE id=?" [| n |] = None then
                fail "undo checkpoint without original move";
              if event = "UNDO_BEGIN" then begin
                let row = Option.get (Db.one db "SELECT rel FROM undo_moves WHERE id=?" [| n |]) in
                let expected =
                  Path.join
                    (Filename.dirname (source h row.(0)))
                    (".filemerge-undo-" ^ h.run_id ^ "-" ^ n ^ ".tmp")
                in
                let temp = string "temporary" json in
                if not (same temp expected) then fail "invalid recovery temporary path";
                Db.run db "UPDATE undo_moves SET undo_started=1,undo_temp=? WHERE id=?"
                  [| temp; n |]
              end
              else if event = "UNDO_COPIED" then
                Db.run db "UPDATE undo_moves SET undo_copy_id=? WHERE id=?"
                  [| string "identity" json; n |]
              else
                Db.run db "UPDATE undo_moves SET undo_id=? WHERE id=?"
                  [| string "identity" json; n |]
          | "PLANNED" | "SCAN_TOTAL" | "CLASSIFICATION_TOTAL" | "PLAN_TOTAL" | "HASH_TOTAL"
          | "IO_PEAK" | "SPACE_BUDGET" | "ERROR" | "END" | "RECOVERY_START" | "RECOVERY_END"
          | "RECOVERY_MKDIR" | "RECOVERY_RMDIR" | "UNDO_REMOVE_COPY" | "UNDO_REMOVE_TEMP"
          | "RECOVERY_LOG_REPAIR" ->
              ()
          | _ -> fail ("unknown transaction record: " ^ event)
        end)
  in
  match !header with Some h -> (h, complete) | None -> fail "no complete transaction header"

let iter_moves db f =
  Db.iter db
    {|SELECT id,rel,dest,size,source_id,copy_id,temp,
  undo_started,undo_copy_id,undo_id,undo_temp,decision,source_readonly FROM undo_moves ORDER BY id DESC|}
    [||] f

let root_for h path =
  if Path.contains ~parent:h.config.keep path then h.config.keep else h.config.quarantine

let validate_roots h log =
  let c = Path.validate h.config in
  if
    not
      (same c.keep h.config.keep && same c.trim h.config.trim
      && same c.quarantine h.config.quarantine)
  then fail "root paths no longer resolve to their recorded locations";
  if Win.identity c.keep <> h.keep_id || Win.identity c.trim <> h.trim_id then
    fail "K or T root identity changed";
  if h.q_id <> "" && ((not (Win.exists c.quarantine)) || Win.identity c.quarantine <> h.q_id) then
    fail "Q root identity changed";
  Path.ensure_outside [| c.keep; c.trim; c.quarantine |] log

let preflight db h log =
  validate_roots h log;
  Db.transaction db (fun () ->
      iter_moves db (fun r ->
          let src = source h r.(1) and dest = r.(2) and size = Int64.of_string r.(3) in
          no_links h.config.trim src;
          no_links (root_for h dest) dest;
          let final_id = if r.(5) = "" then r.(4) else r.(5) in
          let original = identity src and final = identity dest in
          (match final with
          | Some found when found <> final_id -> fail ("destination was replaced: " ^ dest)
          | _ -> ());
          (match original with
          | Some found
            when found <> r.(4)
                 && found <> r.(8)
                 && found <> r.(9)
                 && not (r.(7) = "1" && found = final_id) ->
              fail ("original T path is occupied by a different file: " ^ src)
          | _ -> ());
          let decision =
            match (original, final) with
            | None, Some _ -> Restore
            | Some _, Some _ ->
                equal_content src dest;
                Remove_copy
            | Some _, None -> Already_original
            | None, None -> fail ("neither the original nor moved file exists: " ^ src)
          in
          (match original with
          | Some _ ->
              require_size src size;
              Win.probe src Win.Read_file
          | _ -> ());
          (match final with
          | Some _ ->
              require_size dest size;
              Win.probe dest Win.Remove_file
          | _ -> ());
          (* Known complete temporaries can be cleaned; unknown partial copies are
         deliberately not guessed at after a hard process termination. *)
          let validate_temp temp expected reference =
            if temp <> "" && Win.exists temp then begin
              if expected = "" || identity temp <> Some expected then
                fail ("unidentified temporary file; retain for inspection: " ^ temp);
              require_size temp size;
              equal_content temp reference;
              Win.probe temp Win.Remove_file
            end
          in
          let reference = if original <> None then src else dest in
          if r.(12) <> "" && Win.readonly reference <> (r.(12) = "1") then
            Win.probe reference Win.Write_attributes;
          validate_temp r.(6) r.(5) reference;
          validate_temp r.(10) r.(8) reference;
          let undo_temporary =
            Path.join (Filename.dirname src) (".filemerge-undo-" ^ h.run_id ^ "-" ^ r.(0) ^ ".tmp")
          in
          if r.(10) = "" && Win.exists undo_temporary then
            fail ("unrecorded recovery temporary already exists: " ^ undo_temporary);
          if decision = Restore then begin
            Planner.parents db h.config.trim src;
            let base = Path.ancestor (Filename.dirname src) in
            Space.add db base
              (if Win.volume dest = Win.volume base then 65536L else Win.required_space dest base)
          end;
          Db.run db "UPDATE undo_moves SET decision=? WHERE id=?"
            [| decision_name decision; r.(0) |]);
      (* Restore every directory whose deletion was intended, including a crash
       after RemoveDirectory but before its completion record was flushed. *)
      Db.iter db "SELECT path FROM undo_pruned" [||] (fun r ->
          no_links h.config.trim r.(0);
          if Win.exists r.(0) then Path.directory r.(0)
          else Planner.parents db h.config.trim (Path.join r.(0) ".recovery-parent-probe"));
      Db.iter db "SELECT path,identity FROM undo_dirs ORDER BY length(path) DESC" [||] (fun r ->
          if Win.exists r.(0) then begin
            no_links
              ( Path.ancestor h.config.quarantine |> fun q ->
                if Path.contains ~parent:q r.(0) then q else h.config.keep )
              r.(0);
            Path.directory r.(0);
            if r.(1) = "" || Win.identity r.(0) <> r.(1) then
              fail ("created directory identity is uncertain: " ^ r.(0));
            Win.probe r.(0) Win.Remove_directory;
            Win.with_dir r.(0) (fun directory ->
                Walk.drain
                  ~next:(fun () -> Win.next directory)
                  ~visit:(fun name ->
                    let child = Path.join r.(0) name in
                    let key = Win.key child in
                    if
                      Db.one db "SELECT path FROM undo_dirs WHERE path_key=?" [| key |] = None
                      && Db.one db "SELECT id FROM undo_moves WHERE dest_key=? OR temp=?"
                           [| key; child |]
                         = None
                    then fail ("new content in a directory created by the run: " ^ child)))
          end);
      Db.iter db "SELECT path FROM parents" [||] (fun r ->
          Space.add db (Path.ancestor r.(0)) 65536L);
      let budget =
        Option.get
          (Db.one db
             {|
        SELECT (SELECT coalesce(sum(65536),0) FROM undo_moves) +
          (SELECT coalesce(sum(8192+8*length(CAST(path AS BLOB))),0) FROM parents) +
          (SELECT coalesce(sum(8192+8*length(CAST(path AS BLOB))),0) FROM undo_dirs)
        |}
             [||])
      in
      Space.add db (Filename.dirname log) (Int64.of_string budget.(0));
      Db.iter db "SELECT base,bytes FROM space" [||] (fun r ->
          Space.check r.(0) (Int64.of_string r.(1))))

let execute db h journal =
  Db.iter db "SELECT path FROM parents ORDER BY depth,path" [||] (fun r ->
      Win.mkdir r.(0);
      Journal.emit journal "RECOVERY_MKDIR" [ ("path", Journal.s r.(0)) ]);
  Db.iter db "SELECT path FROM destination_dirs" [||] (fun r -> Win.probe_create r.(0));
  iter_moves db (fun r ->
      let src = source h r.(1) and dest = r.(2) in
      let temporary =
        Path.join (Filename.dirname src) (".filemerge-undo-" ^ h.run_id ^ "-" ^ r.(0) ^ ".tmp")
      in
      (* Preflight established ownership and equivalent retained data for these. *)
      List.iter
        (fun temp ->
          if temp <> "" && Win.exists temp then begin
            Journal.emit journal "UNDO_REMOVE_TEMP"
              [ ("id", Journal.s r.(0)); ("path", Journal.s temp) ];
            Win.unlink temp
          end)
        [ r.(6); r.(10) ];
      Journal.emit journal "UNDO_BEGIN" (("temporary", Journal.s temporary) :: fields r);
      if r.(11) = "restore" then begin
        let io =
          Transfer.
            {
              rename = Win.rename;
              copy =
                (fun a b ->
                  Space.check (Filename.dirname b) (Win.required_space a (Filename.dirname b));
                  Win.copy a b);
              digest = Win.hash;
              size =
                (fun p ->
                  match Win.attributes p with Some m -> m.size | _ -> fail "missing recovery file");
              exists = Win.exists;
              remove = Win.unlink;
              checkpoint =
                (fun event ->
                  if event = "COPIED" then
                    Journal.emit journal "UNDO_COPIED"
                      (("identity", Journal.s (Win.identity temporary)) :: fields r)
                  else
                    Journal.emit journal "UNDO_PUBLISHED"
                      (("identity", Journal.s (Win.identity src)) :: fields r));
            }
        in
        Transfer.move io Verify ~source:dest ~destination:src ~temporary
      end
      else if r.(11) = "remove_copy" then begin
        Journal.emit journal "UNDO_REMOVE_COPY" (fields r);
        Win.unlink dest
      end;
      (* Also repairs a crash between clearing the original flag and deletion.
         BEGIN_MOVE was durable before either could happen; older logs leave it alone. *)
      if r.(12) <> "" && Win.readonly src <> (r.(12) = "1") then Win.set_readonly src (r.(12) = "1");
      Journal.emit journal "UNDO_DONE" (("identity", Journal.s (Win.identity src)) :: fields r));
  Db.iter db "SELECT path FROM undo_dirs ORDER BY length(path) DESC,path DESC" [||] (fun r ->
      if Win.exists r.(0) then begin
        if not (Win.remove_dir r.(0)) then fail ("created directory is not empty: " ^ r.(0));
        Journal.emit journal "RECOVERY_RMDIR" [ ("path", Journal.s r.(0)) ]
      end)

let run path =
  let log =
    try Win.canonical path
    with Failure message -> raise (Config.Error ("Invalid -recover log: " ^ message))
  in
  let initial = header_of_json log (Journal.first log) in
  validate_roots initial log;
  let temp = Win.canonical (Filename.get_temp_dir_name ()) in
  Path.ensure_outside [| initial.config.keep; initial.config.trim; initial.config.quarantine |] temp;
  Space.check temp 0L;
  let state = Filename.temp_file ~temp_dir:temp "filemerge-recovery-" ".sqlite" in
  let db = Db.open_db state and success = ref false in
  Fun.protect
    ~finally:(fun () ->
      Db.close db;
      if !success then Sys.remove state else Printf.eprintf "Recovery index retained: %s\n%!" state)
    (fun () ->
      schema db;
      Printf.printf "Reading transaction log: %s\n%!" log;
      let h, complete = Db.transaction db (fun () -> read db log) in
      Path.ensure_outside [| h.config.keep; h.config.trim; h.config.quarantine |] temp;
      Printf.printf "Preflighting all recovery operations...\n%!";
      preflight db h log;
      let original_length = (Unix.LargeFile.stat log).Unix.LargeFile.st_size in
      let journal = Journal.append log ~complete in
      Fun.protect
        ~finally:(fun () -> Journal.close journal)
        (fun () ->
          try
            if original_length <> complete then
              Journal.emit journal "RECOVERY_LOG_REPAIR"
                [
                  ( "discarded_torn_tail_bytes",
                    `Intlit (Int64.to_string (Int64.sub original_length complete)) );
                ];
            Journal.emit journal "RECOVERY_START" [];
            execute db h journal;
            Journal.emit journal "RECOVERY_END" [ ("outcome", Journal.s "SUCCESS") ];
            success := true;
            Printf.printf "Recovery complete. Original file paths restored.\n%!"
          with e ->
            Journal.error journal "RECOVERY" "" e;
            Journal.emit journal "RECOVERY_END" [ ("outcome", Journal.s "FAILED") ];
            raise e))
