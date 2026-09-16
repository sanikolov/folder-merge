type operation = Plan | Trim | Merge
type links = Skip | Follow
type empty_dirs = Keep | Prune
type verification = Verify | No_verify
type tree = Keeper | Incoming

type config = {
  keep : string;
  trim : string;
  quarantine : string;
  log : string;
  operation : operation;
  parallelism : int;
  links : links;
  empty_dirs : empty_dirs;
  verification : verification;
}

type command = Reconcile of config | Recover of string
type classification = Duplicate_in_keep of string | Unique | Path_collision
type action = Quarantine | Merge_file

type planned = {
  id : string;
  source : string;
  destination : string;
  size : int64;
  action : action;
  classification : classification;
  renamed : bool;
}

let action_name = function Quarantine -> "QUARANTINE" | Merge_file -> "MERGE"
let operation_name = function Plan -> "plan" | Trim -> "trim" | Merge -> "merge"
let tree_name = function Keeper -> "K" | Incoming -> "T"
