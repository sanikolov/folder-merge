(* Conservative budgets include allocation slack and named data streams. Values
   stay int64 throughout, and SQLite detects aggregate integer overflow. *)
let reserve = 67108864L
let fits ~free ~needed = needed >= 0L && free >= reserve && needed <= Int64.sub free reserve

let check path needed =
  let free = Win.free_space path in
  if not (fits ~free ~needed) then
    failwith
      (Printf.sprintf "Insufficient space at %s: need %Ld bytes plus %Ld reserve; available %Ld"
         path needed reserve free)

let add db base bytes =
  Db.run db
    {|INSERT INTO space(volume,base,bytes) VALUES(?,?,?)
    ON CONFLICT(volume) DO UPDATE SET bytes=bytes+excluded.bytes|}
    [| Win.volume base; base; Int64.to_string bytes |]

let preflight db journal c =
  Db.transaction db (fun () ->
      Db.exec db "DELETE FROM space";
      Planner.iter db (fun p ->
          let source = Path.join c.Model.trim p.Model.source in
          let base = Path.ancestor (Filename.dirname p.destination) in
          (* Same-volume renames need metadata slack, not a second content copy. *)
          let bytes =
            if Win.volume source = Win.volume base then 65536L else Win.required_space source base
          in
          add db base bytes);
      Db.iter db "SELECT path FROM parents" [||] (fun r -> add db (Path.ancestor r.(0)) 65536L);
      (* Budget future durable journal records and manifest status updates too.
     Planning records already exist and are reflected in current free space. *)
      let log_directory = Filename.dirname (Journal.path journal) in
      (match
         Db.one db
           {|SELECT coalesce(sum(8192 + 16*(length(CAST(rel AS BLOB))+
    length(CAST(dest AS BLOB))+length(CAST(witness AS BLOB)))),0) FROM plan|}
           [||]
       with
      | Some r -> add db log_directory (Int64.of_string r.(0))
      | None -> ());
      (match
         Db.one db "SELECT coalesce(sum(8192+8*length(CAST(path AS BLOB))),0) FROM parents" [||]
       with
      | Some r -> add db log_directory (Int64.of_string r.(0))
      | None -> ());
      Db.iter db "SELECT base,bytes FROM space" [||] (fun r ->
          let need = Int64.of_string r.(1) in
          check r.(0) need;
          Journal.emit journal "SPACE_BUDGET"
            [
              ("path", Journal.s r.(0));
              ("required_bytes", Journal.s r.(1));
              ("reserve_bytes", `Intlit (Int64.to_string reserve));
              ("available_bytes", `Intlit (Int64.to_string (Win.free_space r.(0))));
            ]))
