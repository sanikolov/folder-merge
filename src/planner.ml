open Model

let reserved db p =
  Option.is_some (Db.one db "SELECT kind FROM reservations WHERE path=?" [| Win.key p |])

let available db p = not (Win.exists p || reserved db p)

let reserve db kind p =
  Db.run db "INSERT INTO reservations(path,kind) VALUES(?,?)" [| Win.key p; kind |]

let destination db intended =
  let dir = Filename.dirname intended and name = Filename.basename intended in
  let candidate = ref intended and n = ref 0 in
  while not (available db !candidate) do
    incr n;
    candidate := Path.join dir (Collision.suffix name !n)
  done;
  Win.validate_destination !candidate;
  reserve db "file" !candidate;
  (!candidate, !n <> 0)

let parents db root dest =
  Db.run db "INSERT OR IGNORE INTO destination_dirs(path) VALUES(?)" [| Filename.dirname dest |];
  (* Reverse order is stored as numeric path length; creation later orders ascending. *)
  let p = ref (Filename.dirname dest) and running = ref true in
  while !running do
    if Win.exists !p then begin
      let m = Option.get (Win.attributes !p) in
      if (not m.directory) || m.reparse then
        failwith ("Destination parent is a file or reparse point: " ^ !p);
      Win.probe !p Win.Add_children;
      running := false
    end
    else begin
      (match Db.one db "SELECT kind FROM reservations WHERE path=?" [| Win.key !p |] with
      | Some row when row.(0) = "file" ->
          failwith ("Destination parent conflicts with a planned file: " ^ !p)
      | Some _ -> ()
      | None -> reserve db "dir" !p);
      Db.run db "INSERT OR IGNORE INTO parents(path,depth) VALUES(?,?)"
        [| !p; string_of_int (String.length !p) |];
      let next = Filename.dirname !p in
      if next = !p then failwith "Cannot establish destination ancestor";
      p := next
    end
  done;
  (* Existing ancestry must stay inside the resolved root; no destination link traversal. *)
  if Win.exists root then begin
    let ancestor = Win.canonical (Filename.dirname dest |> Path.ancestor) in
    if not (Path.contains ~parent:root ancestor) then failwith "Destination escapes root"
  end;
  let ancestor = ref (Path.ancestor (Filename.dirname dest)) in
  while Path.contains ~parent:root !ancestor && Win.key !ancestor <> Win.key root do
    (match Win.attributes !ancestor with
    | Some m when m.reparse ->
        failwith ("Destination ancestry contains a reparse point: " ^ !ancestor)
    | _ -> ());
    ancestor := Filename.dirname !ancestor
  done

let row_to_plan r =
  {
    id = r.(0);
    source = r.(1);
    destination = r.(2);
    action = (if r.(3) = "Q" then Quarantine else Merge_file);
    size = Int64.of_string r.(4);
    classification =
      (if r.(3) = "Q" then Duplicate_in_keep r.(5)
       else if r.(6) = "1" then Path_collision
       else Unique);
    renamed = r.(6) = "1";
  }

let iter db f =
  Db.iter db "SELECT id,rel,dest,action,size,witness,renamed FROM plan ORDER BY id" [||] (fun r ->
      f (row_to_plan r))

let fields p =
  [
    ("id", Journal.s p.id);
    ("action", Journal.s (action_name p.action));
    ("source_relative_to_T", Journal.s p.source);
    ("destination", Journal.s p.destination);
    ("bytes", `Intlit (Int64.to_string p.size));
    ("renamed", `Bool p.renamed);
    ( "witness_relative_to_K",
      match p.classification with Duplicate_in_keep k -> Journal.s k | _ -> `Null );
  ]

let record journal event p = Journal.emit journal event (fields p)

let build db journal c =
  (* SQLite sorts on disk. Reserve parent directory names before file names, so
     future files cannot steal directories needed by a later incoming path. *)
  Db.iter db "SELECT rel FROM dirs WHERE tree='T' AND rel<>'' ORDER BY rel" [||] (fun r ->
      Array.iter
        (fun base ->
          let p = Path.join base r.(0) in
          if not (reserved db p) then reserve db "dir" p)
        [| c.keep; c.quarantine |]);
  Db.iter db
    {|SELECT t.id,t.rel,t.size,
    (SELECT k.rel FROM files k WHERE k.tree='K' AND k.size=t.size AND k.hash=t.hash
       ORDER BY k.rel LIMIT 1) FROM files t WHERE t.tree='T' ORDER BY t.rel COLLATE BINARY|}
    [||] (fun r ->
      let duplicate = r.(3) <> "" in
      if duplicate || c.operation <> Trim then begin
        let root = if duplicate then c.quarantine else c.keep in
        let intended = Path.join root r.(1) in
        (* The complete K index is frozen before any merge: T never deduplicates itself. *)
        parents db root intended;
        let dest, renamed = destination db intended in
        Db.run db "INSERT INTO plan(id,rel,dest,action,size,witness,renamed) VALUES(?,?,?,?,?,?,?)"
          [|
            r.(0);
            r.(1);
            dest;
            (if duplicate then "Q" else "K");
            r.(2);
            r.(3);
            (if renamed then "1" else "0");
          |];
        if c.empty_dirs = Prune then begin
          let rel = ref (Filename.dirname r.(1)) in
          while !rel <> "." do
            Db.run db "INSERT OR IGNORE INTO prune_dirs(rel) VALUES(?)" [| !rel |];
            rel := Filename.dirname !rel
          done
        end
      end);
  iter db (record journal "PLANNED")

let summary db journal =
  Db.iter db
    {|SELECT roots.tree,count(f.id),coalesce(sum(f.size),0)
    FROM (SELECT 'K' AS tree UNION ALL SELECT 'T') roots
    LEFT JOIN files f ON f.tree=roots.tree GROUP BY roots.tree|}
    [||] (fun r ->
      Printf.printf "%s: %s files, %s bytes\n%!" r.(0) r.(1) r.(2);
      Journal.emit journal "SCAN_TOTAL"
        [ ("tree", Journal.s r.(0)); ("files", Journal.s r.(1)); ("bytes", Journal.s r.(2)) ]);
  Db.iter db
    {|SELECT CASE WHEN EXISTS(SELECT 1 FROM files k WHERE k.tree='K' AND
       k.size=t.size AND k.hash=t.hash) THEN 'duplicate' ELSE 'unique' END AS category,
       count(*),coalesce(sum(size),0) FROM files t WHERE tree='T' GROUP BY category|}
    [||] (fun r ->
      Printf.printf "T %s: %s files, %s bytes\n%!" r.(0) r.(1) r.(2);
      Journal.emit journal "CLASSIFICATION_TOTAL"
        [
          ("classification", Journal.s r.(0)); ("files", Journal.s r.(1)); ("bytes", Journal.s r.(2));
        ]);
  Db.iter db
    "SELECT action,renamed,count(*),coalesce(sum(size),0) FROM plan GROUP BY action,renamed" [||]
    (fun r ->
      Printf.printf "%s %s: %s files, %s bytes\n%!"
        (if r.(0) = "Q" then "Quarantine" else "Merge")
        (if r.(1) = "1" then "renamed" else "direct")
        r.(2) r.(3);
      Journal.emit journal "PLAN_TOTAL"
        [
          ("destination_tree", Journal.s r.(0));
          ("renamed", `Bool (r.(1) = "1"));
          ("files", Journal.s r.(2));
          ("bytes", Journal.s r.(3));
        ])
