type t

val create : string -> t
val iter : string -> (Yojson.Safe.t -> unit) -> int64
val first : string -> Yojson.Safe.t
val append : string -> complete:int64 -> t
val path : t -> string
val emit : t -> string -> (string * Yojson.Safe.t) list -> unit
val close : t -> unit
val s : string -> Yojson.Safe.t
val error : t -> string -> string -> exn -> unit
