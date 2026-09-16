open Model

(* Dependency injection keeps the safety state machine testable without disks.
   publish is a no-replace rename; remove is reached only after durable publish. *)
type io = {
  rename : string -> string -> bool;
  copy : string -> string -> unit;
  digest : string -> string;
  size : string -> int64;
  remove : string -> unit;
  exists : string -> bool;
  checkpoint : string -> unit;
}

let move io verification ~source ~destination ~temporary =
  if io.exists temporary then failwith ("Temporary destination already exists: " ^ temporary);
  if io.rename source destination then io.checkpoint "RENAMED"
  else begin
    (* A failed copy never deletes source. Only our exclusive temporary is cleaned. *)
    Fun.protect
      ~finally:(fun () -> if io.exists temporary then try io.remove temporary with _ -> ())
      (fun () ->
        io.copy source temporary;
        (match verification with
        | No_verify -> ()
        | Verify ->
            if io.size source <> io.size temporary || io.digest source <> io.digest temporary then
              failwith "Verification failure: source retained");
        io.checkpoint "COPIED";
        if not (io.rename temporary destination) then
          failwith "Temporary and final destination differ in volume";
        io.checkpoint "DESTINATION_PUBLISHED";
        io.remove source;
        io.checkpoint "SOURCE_REMOVED")
  end
