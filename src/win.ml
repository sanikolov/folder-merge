(* All pathname strings use the OCaml Windows Unicode runtime's UTF-8 encoding.
   Explicit close functions keep native resources independent of GC timing. *)
type directory
type metadata = { directory : bool; reparse : bool; size : int64 }

external attributes : string -> metadata option = "fm_attributes"
external canonical : string -> string = "fm_canonical"
external absolute : string -> string = "fm_absolute"
external key : string -> string = "fm_key"
external identity : string -> string = "fm_identity"
external open_dir : string -> directory = "fm_open_dir"
external next : directory -> string option = "fm_next"
external close_dir : directory -> unit = "fm_close_dir"

type hash_context

external create_hash_context : unit -> hash_context = "fm_hash_context"
external close_hash_context : hash_context -> unit = "fm_hash_context_close"
external native_hash : hash_context -> string -> string = "fm_hash"

let hash_context = Domain.DLS.new_key (fun () -> ref None)

let hash path =
  let cell = Domain.DLS.get hash_context in
  let context =
    match !cell with
    | Some c -> c
    | None ->
        let c = create_hash_context () in
        cell := Some c;
        c
  in
  native_hash context path

let release_hash_context () =
  let cell = Domain.DLS.get hash_context in
  Option.iter close_hash_context !cell;
  cell := None

type access = Read_file | Remove_file | Add_children | Remove_directory | Write_attributes

external native_probe : string -> int -> unit = "fm_probe"

let probe path access =
  native_probe path
    (match access with
    | Read_file -> 0
    | Remove_file -> 1
    | Add_children -> 2
    | Remove_directory -> 3
    | Write_attributes -> 4)

external readonly : string -> bool = "fm_readonly"
external set_readonly : string -> bool -> unit = "fm_set_readonly"
external mkdir : string -> unit = "fm_mkdir"
external remove_dir : string -> bool = "fm_remove_dir"
external rename : string -> string -> bool = "fm_rename"
external copy : string -> string -> unit = "fm_copy"
external unlink : string -> unit = "fm_unlink"
external free_space : string -> int64 = "fm_free_space"
external volume : string -> string = "fm_volume"
external required_space : string -> string -> int64 = "fm_required_space"
external probe_create : string -> unit = "fm_probe_create"
external validate_destination : string -> unit = "fm_validate_destination"
external flush : Unix.file_descr -> unit = "fm_flush"

let with_dir path f =
  let d = open_dir path in
  Fun.protect ~finally:(fun () -> close_dir d) (fun () -> f d)

let exists p = Option.is_some (attributes p)
