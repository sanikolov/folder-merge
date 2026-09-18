open Model

type window = Copied | Published | Undo_published | Unknown_temp | Bad_path

let check message condition = if not condition then failwith message

let write path data =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel data)

let run readonly window =
  let root = Filename.temp_file "filemerge-undo-unit-" "" in
  Sys.remove root;
  Win.mkdir root;
  let k = Path.join root "K" and t = Path.join root "T" and q = Path.join root "Q" in
  List.iter Win.mkdir [ k; t; q ];
  let c =
    Path.validate
      {
        keep = k;
        trim = t;
        quarantine = q;
        log = Path.join root "transaction.log";
        operation = Merge;
        parallelism = 1;
        links = Skip;
        empty_dirs = Keep;
        verification = Verify;
      }
  in
  let src = Path.join c.trim "file" and dest = Path.join c.keep "file" in
  let temp = Path.join c.keep ".folder-merge-unit-1.tmp" in
  let undo_temp = Path.join c.trim ".filemerge-undo-unit-1.tmp" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Win.exists path then Win.unlink path)
        [ src; dest; temp; undo_temp; c.log ];
      List.iter (fun path -> ignore (Win.remove_dir path)) [ k; t; q; root ])
    (fun () ->
      write src "payload";
      Win.set_readonly src readonly;
      let original_id = Win.identity src in
      let plan =
        {
          id = "1";
          source = "file";
          destination = dest;
          size = 7L;
          action = Merge_file;
          classification = Unique;
          renamed = false;
        }
      in
      let journal = Journal.create c.log in
      Fun.protect
        ~finally:(fun () -> Journal.close journal)
        (fun () ->
          Journal.emit journal "START"
            [
              ("format", Journal.s "filemerge-transaction");
              ("version", `Int 1);
              ("run_id", Journal.s "unit");
              ("operation", Journal.s "merge");
              ("keep", Journal.s c.keep);
              ("trim", Journal.s c.trim);
              ("quarantine", Journal.s c.quarantine);
              ("keep_identity", Journal.s (Win.identity c.keep));
              ("trim_identity", Journal.s (Win.identity c.trim));
              ("quarantine_identity", Journal.s (Win.identity c.quarantine));
            ];
          let plan = if window = Bad_path then { plan with source = "..\\outside" } else plan in
          Journal.emit journal "BEGIN_MOVE"
            (Planner.fields plan
            @ [ ("source_identity", Journal.s original_id); ("temporary", Journal.s temp) ]
            @ if readonly then [ ("source_readonly", `Bool true) ] else []);
          if window <> Bad_path then begin
            Win.copy src temp;
            if window <> Unknown_temp then
              Journal.emit journal "COPIED"
                (("copy_identity", Journal.s (Win.identity temp)) :: Planner.fields plan);
            if window = Published || window = Undo_published then begin
              check "publish rename" (Win.rename temp dest);
              if window = Undo_published then begin
                Win.unlink src;
                Journal.emit journal "UNDO_BEGIN"
                  [ ("id", Journal.s "1"); ("temporary", Journal.s undo_temp) ];
                Win.copy dest undo_temp;
                Journal.emit journal "UNDO_COPIED"
                  [ ("id", Journal.s "1"); ("identity", Journal.s (Win.identity undo_temp)) ];
                check "undo publication" (Win.rename undo_temp src)
              end
            end
          end);
      if readonly && (window = Published || window = Undo_published) then Win.set_readonly src false;
      if window = Unknown_temp || window = Bad_path then begin
        check "unsafe log/window refused"
          (try
             Recovery.run c.log;
             false
           with Failure _ -> true);
        check "original preserved on refused recovery" (Win.identity src = original_id);
        if window = Unknown_temp then check "unknown temp preserved" (Win.exists temp)
      end
      else begin
        Recovery.run c.log;
        check "original readonly restored" (Win.readonly src = readonly);
        check "original content restored"
          (Win.hash src
          =
          let p = Path.join root "expected" in
          write p "payload";
          Fun.protect ~finally:(fun () -> Win.unlink p) (fun () -> Win.hash p));
        check "transaction copies removed"
          (not (Win.exists dest || Win.exists temp || Win.exists undo_temp));
        Recovery.run c.log
      end)

let () =
  List.iter
    (fun readonly ->
      List.iter (run readonly) [ Copied; Published; Undo_published; Unknown_temp; Bad_path ])
    [ false; true ];
  Win.release_hash_context ();
  print_endline "Passed 10 native recovery interruption/safety scenarios"
