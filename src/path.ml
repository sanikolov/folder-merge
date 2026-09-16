open Model

let join parent child = if child = "" then parent else Filename.concat parent child

let contains ~parent child =
  let a = Win.key parent and b = Win.key child in
  a = b || String.starts_with ~prefix:(if Filename.check_suffix a "\\" then a else a ^ "\\") b

let directory p =
  match Win.attributes p with
  | Some m when m.directory -> ()
  | _ -> failwith ("Not a directory: " ^ p)

(* Find the nearest existing ancestor without a recursion chain. *)
let ancestor p =
  let current = ref p in
  while not (Win.exists !current) do
    let next = Filename.dirname !current in
    if next = !current then failwith ("No accessible ancestor: " ^ p);
    current := next
  done;
  directory !current;
  !current

let prospective p =
  let abs = Win.absolute p in
  let base = ancestor abs in
  let suffix = String.sub abs (String.length base) (String.length abs - String.length base) in
  Win.canonical base ^ suffix

let validate c =
  directory c.keep;
  directory c.trim;
  let k = Win.canonical c.keep and t = Win.canonical c.trim and q = prospective c.quarantine in
  let roots = [| k; t; q |] in
  for i = 0 to 2 do
    for j = i + 1 to 2 do
      if contains ~parent:roots.(i) roots.(j) || contains ~parent:roots.(j) roots.(i) then
        invalid_arg "K, T and Q must be distinct and pairwise non-nested (including aliases)";
      if
        Win.exists roots.(i)
        && Win.exists roots.(j)
        && Win.identity roots.(i) = Win.identity roots.(j)
      then invalid_arg "K, T and Q refer to the same directory"
    done
  done;
  { c with keep = k; trim = t; quarantine = q }

let relative ~root p =
  if not (contains ~parent:root p) then failwith ("Link escapes its tree: " ^ p);
  if Win.key root = Win.key p then ""
  else
    let start = String.length root + if Filename.check_suffix root "\\" then 0 else 1 in
    String.sub p start (String.length p - start)

let ensure_outside roots p =
  Array.iter
    (fun r -> if contains ~parent:r p then failwith "Run state must be outside K, T and Q")
    roots

let new_log c =
  let abs = Win.absolute c.log in
  let parent = Filename.dirname abs in
  directory parent;
  let path = join (Win.canonical parent) (Filename.basename abs) in
  ensure_outside [| c.keep; c.trim; c.quarantine |] path;
  Win.validate_destination path;
  if Win.exists path then
    invalid_arg ("Transaction log already exists; choose a new -log path: " ^ path);
  path
