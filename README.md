# Folder Merge

A native Windows command-line reconciler written in OCaml 5.5, with small C
bindings for Windows filesystem operations, SHA-256, and the system SQLite DLL.
Existing files in **K** and **Q** are never overwritten. Files removed from **T**
are moved to K or Q, never discarded as duplicates.

## Build and test

Requires Windows 10/11, the native Unicode-enabled OCaml 5.5 compiler, Dune,
Yojson, and the MinGW compiler supplied with this OCaml installation.
No dependency download is performed during the build.

```powershell
.\build.ps1
.\build.ps1 -Test
# Optional alternate installation:
.\build.ps1 -OcamlRoot F:\tools\ocaml
```

The release executable is `dist\filemerge.exe`. The build uses Dune's release profile,
`ocamlopt -O3`, and `-O3` for the native bindings. The supplied OCaml installation
does not enable Flambda; `-O3` does not add Flambda to that compiler.
The executable uses Windows' `bcrypt.dll` and `winsqlite3.dll`; a separate SQLite
installation is unnecessary. SQLite is loaded explicitly from System32.

Tests create their own fixtures under ignored `test-results\run-*` directories.
Junctions are removed in a `finally` block, including when a test fails. After a
forced termination, remove any leftover links safely with
`.\tests\clean-test-links.ps1` before using Git cleanup. For genuinely deep test
directories, use `git -c core.longpaths=true clean -fdx -- test-results`.
The build only searches `src` and `tests`, so fixture junction cycles cannot be
followed by Dune. To increase real filesystem stress:

```powershell
.\tests\integration.ps1 -BroadCount 20000 -Depth 1000
# Optional, on a writable test share:
.\tests\integration.ps1 -UncRoot '\\server\share\test-area'
```

## Invocation

All eleven reconciliation options must occur exactly once. There are no command-line defaults.
Invoking `filemerge.exe` without arguments or with invalid arguments prints usage
and exits nonzero. Invalid arguments also produce a specific error identifying
the missing option, repeated option, invalid value, or unsafe folder relationship.
Use `filemerge.exe --help` (also `-help` or `-h`) for help with a successful exit.

```powershell
.\dist\filemerge.exe `
  -keep 'F:\keeper' `
  -trim 'F:\incoming' `
  -quarantine 'G:\quarantine' `
  -operation plan `
  -hash sha256 `
  -parallelism 4 `
  -collision rename `
  -links skip `
  -empty-dirs keep `
  -verify yes `
  -log 'F:\logs\transaction.log'
```

| Option | Allowed values and meaning |
| --- | --- |
| `-keep` | Existing authoritative directory K |
| `-trim` | Existing incoming directory T |
| `-quarantine` | Directory Q; missing ancestors may be created during execution |
| `-operation` | `plan`, `trim`, or `merge` |
| `-hash` | `sha256` |
| `-parallelism` | Integer `1` through `8` |
| `-collision` | `rename` |
| `-links` | `skip` or `follow` |
| `-empty-dirs` | `keep` or `prune` |
| `-verify` | `yes` or `no` |
| `-log` | New transaction log outside K/T/Q; its parent directory must exist |

Use a fresh log filename for every normal run, including `plan`. Existing logs
are never overwritten. Keep the log until you are sure you will not need to undo
the run. Older automatically generated journals without the versioned transaction
header cannot be used for recovery.

## Recover a run

Recovery has its own invocation; do not supply the reconciliation options:

```powershell
.\dist\filemerge.exe -recover 'F:\logs\transaction.log'
```

This reverses the operations recorded in that log, in reverse execution order:

- Quarantined files return from their actual Q locations to their original T paths.
- Merged files return from K to their original T paths. A file moved to
  `K\report (2).pdf` returns to `T\report.pdf`, not to the collision-generated name.
- Pruned T directories are recreated. Directories created by the original run
  beneath K/Q, including a previously absent Q root and its new ancestors, are
  removed only when empty. Pre-existing K/Q files and directories remain intact.

Recovery restores the file layout and transferred content. It is not a backup
of later edits, and does not restore directory timestamps, ACLs, or deleted files
that somebody removed after the run. Keep all trees unchanged between the
original operation and recovery. Use one filemerge process at a time.

The entire reversal is preflighted before any file moves. Recovery checks root
and file identities, sizes, path containment, reparse points, permissions, locks,
and space budgets. It refuses occupied original paths, replaced/missing files,
or unrecorded content in directories it would need to remove. It never renames
an occupant out of the way or overwrites it. Recovery runs serially and always
verifies cross-volume copies with size and SHA-256 before removing their source.

Recovery progress is appended and flushed to the **same transaction log**. You
can rerun `-recover` after an interruption; already restored files are recognized,
and a second successful recovery is harmless. A plan-only log makes no file moves.
If an unexpected device/write failure occurs during recovery, completed undo
operations remain completed and the log supports retrying the remainder.

Durable move-intent records let recovery recognize a same-volume rename whose
completion record was lost. Physical copies have a durable identity checkpoint
before publication. When both original and newly copied files remain, recovery
compares them and removes only the identified transaction copy. A torn final
log record is discarded after preflight and that repair is itself recorded.
Malformed complete records are rejected. A hard termination during an
uncheckpointed copy or directory creation can leave an object whose identity was
never logged; recovery conservatively refuses it for manual inspection instead
of guessing ownership. Do not edit the log or recover logs from untrusted sources.

K, T, and Q must be **three distinct, pairwise non-nested directories**.
Equality, case aliases, trailing separators, relative forms, and junction aliases
are checked using resolved Windows paths and directory identities. Q cannot
contain K/T either. Failure to establish safe relationships is an error before
scanning. Ordinary Windows case-insensitive destination semantics are used
conservatively even if a directory enables case-sensitive names.

`plan` describes a full **merge**, including the quarantine subset that a `trim`
would perform. It does not create, rename, delete, or write anything in K/T/Q.
Its only writes are run state and reporting outside those trees. Actual execution
recomputes the plan from the filesystem; there is no stale-plan replay option.

`trim` quarantines only files already represented in the original K.
`merge` quarantines those duplicates and moves the remaining T files into K.
Identical files occurring only within T both survive classification and both
move into K. Newly merged files never enter the duplicate-discovery index.

## Pipeline and functional design

Configuration and domain records are immutable. Operations, link policies,
verification policies, actions, and classifications use algebraic data types.
Parsing and filename transformations are pure. Filesystem, database, journal,
and scheduler effects are isolated in dedicated modules; database, pool, and
journal state are abstract behind interfaces. The transfer state machine accepts
an explicit I/O record so failures can be tested independently of Windows.

1. Resolve and validate root relationships.
2. Stream directory entries into a disk-backed SQLite manifest. Directory
   identities and the pending traversal queue also live on disk.
3. Check read access, sharing restrictions, and byte-range locks. For mutation
   runs, check delete access and, for read-only incoming files, attribute-write access.
   Read-only files are supported: copies retain the flag, source deletion clears it
   temporarily and restores it on failure. The original flag is recorded before each
   move so recovery can restore it even after an interrupted attribute change.
   Older journals without that field preserve the surviving file's current flag.
4. Hash only sizes occurring in both K and T. SHA-256 uses Windows CNG and a
   reusable 1 MiB native buffer per worker. The index stores 32-byte digests.
5. Classify against the complete original K index, then persist destinations in
   deterministic relative-path order. An identical existing K destination is
   already represented in this content index, regardless of its name.
6. Validate parents, reserve names, preflight every planned source and affected
   prune directory, and compute per-volume space budgets.
7. For mutation runs, create required destination directories and test actual
   create/write/flush/delete access in each destination directory. These tiny,
   exclusive temporary probes are removed immediately. This catches inherited
   file ACL restrictions before any T file moves. If this preparation fails,
   newly created empty directories are removed where possible.
8. Execute the persisted plan, then optionally prune newly emptied T ancestors.

A file/directory conflict in a required parent path is refused during planning.
For a collision at the final filename, the incoming file receives the first
unused suffix: `report.pdf`, `report (1).pdf`, `report (2).pdf`, etc. Dotfiles
and multiple periods are handled without splitting filenames manually.
Directory names needed by later incoming files are reserved first. SQLite
reservations use Windows-normalized case keys; allocation and transfer are
serialized. Every final rename independently enforces no replacement.

## Stack, memory, and concurrency

Filesystem traversal uses an iterative driver with a disk-backed queue, one
enumeration handle at a time, and no recursion proportional to directory depth.
There is no `Sys.readdir` array of an entire directory and no whole-tree list.
Parent creation, pruning, report iteration, collision searching, and hashing
batches are iterative. The scheduler's only recursive routine is a tail call
retrying an atomic maximum update.

The manifest has an 8 MiB SQLite page-cache target, disk-backed temporary sorting,
disabled memory mapping, and a maximum of 64 cached prepared statements. It
stores file paths relative to K/T. At most 32 hash jobs and results are resident
per batch. File data never enters an OCaml string; only the 32-byte result does.
Native hash buffers are reused and explicitly released when workers stop.
Memory is bounded by these structures and individual path lengths, rather than
file bytes or total entry count. SQLite/runtime/OS overhead adds to these bounds;
8 MiB is not a process RSS ceiling. Disk manifest and journal size grow with the
number and length of paths.

Exactly N fixed worker domains handle hashing. The coordinator does no tree
scanning, copying, or other file hashing while a batch is active. Scanning and
transfers are serial phases, so combined scanning/hashing/copying concurrency
never exceeds N. SQLite and journal bookkeeping are handled by one owner;
workers never touch their state. `IO_PEAK` records the observed hash-job peak.

## Space checks

Before execution, all planned requirements are added **by destination volume**,
including when K and Q share a volume. Estimates include:

- Cross-volume file contents, including named data streams, rounded upward to
  at least 64 KiB allocation units; sparse/compressed source savings are not assumed.
- Metadata headroom of 64 KiB per transfer and new directory. Same-volume moves
  do not require a second file-data allocation.
- Future operation and directory journal records on the log's volume. Temporary
  manifest growth on `%TEMP%` is also checked as the index is written.
- An additional 64 MiB free-space reserve on each involved volume.

The estimate deliberately errs toward refusing tight-space runs. It does not
credit space that later T removals might free. Before each physical copy, the
current free space is checked again against the entire copy requirement.
Manifest and journal growth also check run-state free space periodically and
abort below the reserve. Keep `%TEMP%` on a volume with enough room for the
metadata of large runs. SQLite itself reports allocation and disk-full errors.

These checks are estimates, not storage reservations. Quotas, filesystem metadata
growth, network storage behavior, and later device faults can still cause an
operation to fail. There is no portable preflight that guarantees every later
write will succeed. All trees, permissions, locks, and available space are
assumed stable during a run; snapshots and change detection are outside scope.

## Moves and failure safety

Same-volume moves use `MoveFileExW` without `REPLACE_EXISTING` or `COPY_ALLOWED`.
A successful rename is not rehashed. Only `ERROR_NOT_SAME_DEVICE` selects the
cross-volume path; access/sharing errors never silently fall back to copying.

For cross-volume moves, `CopyFileW` writes an exclusive temporary sibling of the
destination and the result is flushed. This preserves Windows streams and
metadata as supported by the destination filesystem. With `-verify yes`, size
and SHA-256 of the primary stream are compared before publication. The temporary
file is then renamed without replacement to the final name. Only after durable
publication is journaled is the source removed. `-verify no` skips the extra
content reads but still requires successful copy and flush.

Copy/verification/publication failure leaves the T source intact and attempts
to remove this run's temporary file. A failure after publication but before
source removal may leave **both** copies; the journal distinguishes this case.
Execution stops on an unexpected transfer failure. Already completed moves are
not rolled back. The run is not an all-or-nothing filesystem transaction, and
power loss or forced process termination can leave temporary files for manual
inspection. Use the explicit `-recover` command to undo a run; normal invocation
never automatically undoes earlier work.

## Links and empty directories

`skip` excludes all reparse entries, including file symlinks, junctions, and
directory links. `follow` resolves links and uses persistent directory identities
to prevent cycles. Following a link is permitted **only within its own resolved
root**; a link escaping into another tree or an unrelated location refuses the
run. Files reached through aliases are indexed by their resolved relative path.
Link entries themselves are preserved, so they can become dangling after their
target moves. Destination parent paths containing reparse points are refused.
Root junctions are resolved before these rules are applied.

`keep` leaves T directories in place. `prune` considers only ancestors of
successfully moved files, deepest first; pre-existing empty directories and the
T root remain. `RemoveDirectoryW` checks actual emptiness; a remaining link or
file prevents removal. Q directories are never pruned. Empty T directories are
not materialized in K merely because a merge was requested.

Unicode and extended-length Windows paths are used throughout. UNC roots can be
used when the server supports the required file identity, lock, permissions,
stream, and rename APIs; otherwise the run fails conservatively. No live UNC
server is required by the local test suite. Generated paths exceeding Windows
component/length limits are rejected before execution.

## Reports and diagnostics

The console prints aggregate counts and the JSON Lines transaction log path
supplied with `-log`. The log includes supplied arguments,
resolved roots, timestamps, counts/bytes, every planned mapping, collision flags,
duplicate witnesses, space estimates, access/hash/transfer errors, and the final
outcome. Source-removing operations have flushed intent and checkpoint records.
Normal output does not list millions of filenames.

Successful runs remove the temporary SQLite manifest from `%TEMP%` and retain the log.
Failed runs retain both for diagnosis. Root/CLI validation failures occur before
safe run-state creation and are reported to stderr. Any failure exits nonzero.
After a partial transfer, use the original transaction log with `-recover` to undo
it before starting a fresh reconciliation. `BEGIN_MOVE`, `COPIED`, `RENAMED`,
`DESTINATION_PUBLISHED`, `SOURCE_REMOVED`, `DONE`, and `ERROR` record forward
progress; `UNDO_*` and `RECOVERY_*` record recovery progress.

## Verification coverage

The automated suite covers required CLI options and invalid values; empty trees;
same/different-name duplicates; equal-size different contents; internal T
duplicates; repeated filename and Q collisions; Unicode/spaces; keep/prune;
deep and broad trees; all equal-root pairs and nesting directions; junction
aliases, cycles, and escapes; locked/readonly/inaccessible files and directories;
same-volume moves; SHA-256 known vectors; database rollback and binary digests;
and instrumented worker bounds for N=1..8.

A million-level synthetic traversal uses the same traversal driver as scanning.
Injected transfer tests cover partial copy, failed verification, failed
publication, failed publication journaling, and no-overwrite behavior. When
`%TEMP%` is on a different volume, integration tests also perform a real
cross-volume copy/verify/remove and use a sparse file larger than available
destination space to verify pre-execution refusal. Unsupported optional tests
print an explicit skip. No tests exhaust the real disk.

Recovery tests compare the original and recovered K/T/Q trees, exercise repeated
recovery, rename collisions, missing Q roots, interrupted copy/publication
checkpoints, torn records, unsafe paths, locked files, occupied T paths, replaced
destinations, existing-log refusal, and real cross-volume undo. Known complete
copy leftovers are recovered; unidentified temporary files are preserved on refusal.

Implementation references: [Windows file access rights](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights),
[SQLite C API](https://www.sqlite.org/c3ref/intro.html), and
[Windows SQLite support](https://learn.microsoft.com/en-us/windows/apps/develop/data-access/sqlite-data-access).
