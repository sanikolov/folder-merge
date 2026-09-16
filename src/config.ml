open Model

exception Error of string

let usage =
  {|Usage:
  filemerge.exe -keep <K> -trim <T> -quarantine <Q>
    -operation <plan|trim|merge> -hash <sha256> -parallelism <1..8>
    -collision <rename> -links <skip|follow>
    -empty-dirs <keep|prune> -verify <yes|no> -log <transaction.log>

Recovery usage:
  filemerge.exe -recover <transaction.log>
  Reverse the logged run, restoring original T paths without overwriting files.
  Recovery takes no other options and always verifies physical copies.

All eleven reconciliation options are mandatory and must occur exactly once.
  -keep          Existing authoritative directory; never overwritten.
  -trim          Existing incoming directory to reconcile.
  -quarantine    Destination for duplicates; may be created during execution.
  -operation     plan: preview a full merge without changing K/T/Q.
                 trim: quarantine duplicates only. merge: also move unique files.
  -hash          SHA-256 is the only supported content hash.
  -parallelism   Maximum concurrent filesystem jobs, from 1 through 8.
  -collision     Rename incoming files when their destination is occupied.
  -links         Skip links, or follow links within their own tree with cycle checks.
  -empty-dirs    Keep directories, or prune newly emptied T directories.
  -verify        Verify copied content before removing its source (yes or no).
  -log           New transaction log outside K/T/Q; never overwrite an existing log.

K, T and Q must be distinct and pairwise non-nested, including path aliases.
Quote paths containing spaces. Use -help, --help or -h to show this help.

Example:
  filemerge.exe -keep "F:\keeper" -trim "F:\incoming" -quarantine "G:\quarantine" -operation merge -hash sha256 -parallelism 4 -collision rename -links skip -empty-dirs keep -verify yes -log "F:\logs\transaction.log"
  filemerge.exe -recover "F:\logs\transaction.log"
|}

let options =
  [|
    "-keep";
    "-trim";
    "-quarantine";
    "-operation";
    "-hash";
    "-parallelism";
    "-collision";
    "-links";
    "-empty-dirs";
    "-verify";
    "-log";
  |]

let parse argv =
  let fail s = raise (Error s) in
  if Array.length argv <= 1 then fail "No parameters supplied.";
  (* Tail recursion and at most eleven immutable bindings, even for enormous argv. *)
  let rec collect i pairs =
    if i = Array.length argv then pairs
    else
      let name = argv.(i) in
      if not (Array.mem name options) then
        fail (Printf.sprintf "Unknown option or unexpected argument %S." name);
      if List.mem_assoc name pairs then fail ("Option " ^ name ^ " was supplied more than once.");
      if i + 1 = Array.length argv || Array.mem argv.(i + 1) options then
        fail ("Missing value for " ^ name ^ ".");
      let value = argv.(i + 1) in
      if value = "" then fail ("Empty value for " ^ name ^ ".");
      collect (i + 2) ((name, value) :: pairs)
  in
  let pairs = collect 1 [] in
  let missing =
    Array.to_list options |> List.filter (fun name -> not (List.mem_assoc name pairs))
  in
  if missing <> [] then fail ("Missing required option(s): " ^ String.concat ", " missing ^ ".");
  let get name = List.assoc name pairs in
  let select name cases =
    let v = get name in
    match List.assoc_opt v cases with
    | Some x -> x
    | None ->
        fail
          (Printf.sprintf "Invalid value %S for %s; expected %s." v name
             (String.concat "|" (List.map fst cases)))
  in
  let () = select "-hash" [ ("sha256", ()) ] and () = select "-collision" [ ("rename", ()) ] in
  let n = get "-parallelism" in
  if String.length n <> 1 || n.[0] < '1' || n.[0] > '8' then
    fail
      (Printf.sprintf "Invalid value %S for -parallelism; expected an integer from 1 through 8." n);
  {
    keep = get "-keep";
    trim = get "-trim";
    quarantine = get "-quarantine";
    log = get "-log";
    operation = select "-operation" [ ("plan", Plan); ("trim", Trim); ("merge", Merge) ];
    parallelism = int_of_string n;
    links = select "-links" [ ("skip", Skip); ("follow", Follow) ];
    empty_dirs = select "-empty-dirs" [ ("keep", Keep); ("prune", Prune) ];
    verification = select "-verify" [ ("yes", Verify); ("no", No_verify) ];
  }

let command argv =
  if Array.exists (( = ) "-recover") argv then begin
    if Array.length argv = 2 && argv.(1) = "-recover" then
      raise (Error "Missing value for -recover.");
    if Array.length argv <> 3 || argv.(1) <> "-recover" then
      raise
        (Error
           "Recovery requires exactly -recover <transaction.log>; do not combine it with \
            reconciliation options.");
    if argv.(2) = "" || String.starts_with ~prefix:"-" argv.(2) then
      raise (Error "Missing or invalid transaction log path for -recover.");
    Recover argv.(2)
  end
  else Reconcile (parse argv)
