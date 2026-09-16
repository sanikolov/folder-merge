open Model

let root c = function Keeper -> c.keep | Incoming -> c.trim

let run db journal c tree =
  let base = root c tree and tag = tree_name tree in
  let errors = ref 0 in
  let attempt path f =
    try f ()
    with exn ->
      incr errors;
      Journal.error journal "SCAN_PREFLIGHT" path exn
  in
  Db.run db "INSERT INTO dirs(tree,rel,identity) VALUES(?,?,?)" [| tag; ""; Win.identity base |];
  Walk.drain
    ~next:(fun () ->
      Db.one db "SELECT id,rel FROM dirs WHERE tree=? AND done=0 ORDER BY id LIMIT 1" [| tag |])
    ~visit:(fun row ->
      let path = Path.join base row.(1) in
      attempt path (fun () ->
          Win.with_dir path (fun dir ->
              let more = ref true in
              while !more do
                match Win.next dir with
                | None -> more := false
                | Some name ->
                    let child = Path.join path name in
                    attempt child (fun () ->
                        let initial =
                          match Win.attributes child with
                          | Some m -> m
                          | None -> failwith "Entry disappeared"
                        in
                        if not (initial.reparse && c.links = Skip) then begin
                          let actual = if initial.reparse then Win.canonical child else child in
                          let rel = Path.relative ~root:base actual in
                          let meta =
                            match Win.attributes actual with
                            | Some m -> m
                            | None -> failwith "Broken link"
                          in
                          if meta.directory then
                            Db.run db "INSERT OR IGNORE INTO dirs(tree,rel,identity) VALUES(?,?,?)"
                              [| tag; rel; Win.identity actual |]
                          else begin
                            (* Even unmatched-size files get read/access/lock preflight. *)
                            Win.probe actual
                              (if tree = Incoming && c.operation <> Plan then Win.Remove_file
                               else Win.Read_file);
                            Db.run db "INSERT OR IGNORE INTO files(tree,rel,size) VALUES(?,?,?)"
                              [| tag; rel; Int64.to_string meta.size |]
                          end
                        end)
              done));
      Db.run db "UPDATE dirs SET done=1 WHERE id=?" [| row.(0) |]);
  !errors

let hash_candidates db journal c pool =
  let errors = ref 0 and last = ref "0" and more = ref true in
  while !more do
    let rows = ref [] in
    Db.iter db
      {|SELECT f.id,f.tree,f.rel FROM files f WHERE f.id>CAST(? AS INTEGER)
      AND EXISTS(SELECT 1 FROM files g WHERE g.tree=CASE f.tree WHEN 'K' THEN 'T' ELSE 'K' END AND g.size=f.size)
      ORDER BY f.id LIMIT 32|}
      [| !last |] (fun r -> rows := r :: !rows);
    let batch = Array.of_list (List.rev !rows) in
    if Array.length batch = 0 then more := false
    else begin
      let results = Array.make (Array.length batch) (Ok "") in
      Pool.run pool
        (Array.mapi
           (fun i r ->
             fun () ->
              let base = if r.(1) = "K" then c.keep else c.trim in
              results.(i) <- (try Ok (Win.hash (Path.join base r.(2))) with exn -> Error exn))
           batch);
      Array.iteri
        (fun i r ->
          (match results.(i) with
          | Ok hash -> Db.update_digest db ~id:r.(0) ~digest:hash
          | Error exn ->
              incr errors;
              Journal.error journal "HASH"
                (Path.join (if r.(1) = "K" then c.keep else c.trim) r.(2))
                exn);
          last := r.(0))
        batch
    end
  done;
  !errors
