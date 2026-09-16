let () =
  Printexc.record_backtrace true;
  if Array.length Sys.argv = 2 && List.mem Sys.argv.(1) [ "-h"; "-help"; "--help" ] then (
    print_string Config.usage;
    exit 0);
  try
    Fun.protect ~finally:Win.release_hash_context (fun () ->
        match Config.command Sys.argv with
        | Model.Reconcile c -> Engine.run c Sys.argv
        | Model.Recover path -> Recovery.run path)
  with
  | Config.Error message ->
      Printf.eprintf "ERROR: %s\n\n%s%!" message Config.usage;
      exit 1
  | e ->
      Printf.eprintf "ERROR: %s\n%!" (Printexc.to_string e);
      exit 1
