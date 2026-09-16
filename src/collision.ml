(* Pure, deterministic filename transformation. Dotfiles keep their full stem. *)
let suffix name n =
  let ext = Filename.extension name in
  let stem = if ext = name then name else Filename.remove_extension name in
  let ext = if ext = name then "" else ext in
  Printf.sprintf "%s (%d)%s" stem n ext
