type t
(** Single-owner disk index. Statements are cached with a hard 64-entry bound. *)

val open_db : string -> t
val close : t -> unit
val exec : t -> string -> unit
val run : t -> string -> string array -> unit
val update_digest : t -> id:string -> digest:string -> unit
val one : t -> string -> string array -> string array option
val iter : t -> string -> string array -> (string array -> unit) -> unit
val transaction : t -> (unit -> 'a) -> 'a
val schema : t -> unit
