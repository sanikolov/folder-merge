type t
(** Fixed domains; at most 32 jobs per batch. Results belong to the caller. *)

val with_pool : int -> (t -> 'a) -> 'a
val run : t -> (unit -> unit) array -> unit
val peak : t -> int
