(* The traversal driver is independent of filesystem depth and queue storage. *)
let drain ~next ~visit =
  let running = ref true in
  while !running do
    match next () with None -> running := false | Some item -> visit item
  done
