(* Fixed domains and a bounded batch: no per-file domain or growing job queue.
   Only this boundary contains scheduler mutation. The caller is the sole DB owner. *)
type job = unit -> unit

type t = {
  mutex : Mutex.t;
  ready : Condition.t;
  finished : Condition.t;
  mutable batch : job array;
  mutable next : int;
  mutable remaining : int;
  mutable stopped : bool;
  mutable failure : exn option;
  mutable domains : unit Domain.t array;
  active : int Atomic.t;
  peak : int Atomic.t;
}

let rec raise_peak peak n =
  let old = Atomic.get peak in
  if n > old && not (Atomic.compare_and_set peak old n) then raise_peak peak n

let worker t () =
  Fun.protect ~finally:Win.release_hash_context (fun () ->
      let running = ref true in
      while !running do
        Mutex.lock t.mutex;
        while t.next = Array.length t.batch && not t.stopped do
          Condition.wait t.ready t.mutex
        done;
        if t.stopped then (
          Mutex.unlock t.mutex;
          running := false)
        else begin
          let job = t.batch.(t.next) in
          t.next <- t.next + 1;
          Mutex.unlock t.mutex;
          let n = Atomic.fetch_and_add t.active 1 + 1 in
          raise_peak t.peak n;
          let result =
            try
              job ();
              None
            with exn -> Some exn
          in
          ignore (Atomic.fetch_and_add t.active (-1));
          Mutex.lock t.mutex;
          (match (result, t.failure) with Some e, None -> t.failure <- Some e | _ -> ());
          t.remaining <- t.remaining - 1;
          if t.remaining = 0 then Condition.signal t.finished;
          Mutex.unlock t.mutex
        end
      done)

let create n =
  if n < 1 || n > 8 then invalid_arg "Pool size must be 1..8";
  let t =
    {
      mutex = Mutex.create ();
      ready = Condition.create ();
      finished = Condition.create ();
      batch = [||];
      next = 0;
      remaining = 0;
      stopped = false;
      failure = None;
      domains = [||];
      active = Atomic.make 0;
      peak = Atomic.make 0;
    }
  in
  (try
     for _ = 1 to n do
       t.domains <- Array.append t.domains [| Domain.spawn (worker t) |]
     done
   with e ->
     Mutex.lock t.mutex;
     t.stopped <- true;
     Condition.broadcast t.ready;
     Mutex.unlock t.mutex;
     Array.iter Domain.join t.domains;
     raise e);
  t

let run t jobs =
  if Array.length jobs > 32 then invalid_arg "Pool batch exceeds 32";
  Mutex.lock t.mutex;
  t.batch <- jobs;
  t.next <- 0;
  t.remaining <- Array.length jobs;
  t.failure <- None;
  Condition.broadcast t.ready;
  while t.remaining > 0 do
    Condition.wait t.finished t.mutex
  done;
  let failure = t.failure in
  t.batch <- [||];
  t.next <- 0;
  Mutex.unlock t.mutex;
  Option.iter raise failure

let close t =
  Mutex.lock t.mutex;
  t.stopped <- true;
  Condition.broadcast t.ready;
  Mutex.unlock t.mutex;
  Array.iter Domain.join t.domains

let with_pool n f =
  let t = create n in
  Fun.protect ~finally:(fun () -> close t) (fun () -> f t)

let peak t = Atomic.get t.peak
