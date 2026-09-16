param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$checks=0
function Check([bool]$ok,[string]$why) { $script:checks++; if (-not $ok) { throw "Recovery assertion: $why" } }
function Case([string]$name) {
    $root=Join-Path $TestRoot ("recovery-$name")
    foreach ($tree in 'K','T','Q') { [IO.Directory]::CreateDirectory("$root\$tree") | Out-Null }
    return @{ K="$root\K"; T="$root\T"; Q="$root\Q"; Log="$root\transaction.log" }
}
function Put([string]$path,[string]$value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path,$value,[Text.UTF8Encoding]::new($false))
}
function Snapshot([string]$root) {
    if (-not [IO.Directory]::Exists($root)) { return 'ABSENT' }
    return (@(Get-ChildItem -LiteralPath $root -Force -Recurse | ForEach-Object {
        $relative=$_.FullName.Substring($root.Length)
        if ($_.PSIsContainer) { "D|$relative" } else { "F|$relative|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    } | Sort-Object) -join "`n")
}
function Forward($c,[string]$operation='merge',[bool]$success=$true) {
    $cli=@('-keep',$c.K,'-trim',$c.T,'-quarantine',$c.Q,'-operation',$operation,'-hash','sha256',
        '-parallelism','2','-collision','rename','-links','skip','-empty-dirs','prune','-verify','yes','-log',$c.Log)
    $output=(& $Executable @cli 2>&1 | Out-String)
    Check (($LASTEXITCODE -eq 0) -eq $success) "forward exit: $output"
}
function Recover($c,[bool]$success=$true) {
    $output=(& $Executable -recover $c.Log 2>&1 | Out-String)
    Check (($LASTEXITCODE -eq 0) -eq $success) "recover exit: $output"
}
function Truncate-After($c,[string]$event) {
    $lines=[IO.File]::ReadAllLines($c.Log)
    $end=-1
    for ($i=0; $i -lt $lines.Length; $i++) { if (($lines[$i] | ConvertFrom-Json).event -eq $event) { $end=$i } }
    if ($end -lt 0) { throw "No $event record" }
    [IO.File]::WriteAllLines($c.Log,$lines[0..$end],[Text.UTF8Encoding]::new($false))
}

foreach ($operation in 'merge','trim','plan') {
    $c=Case $operation
    Put "$($c.K)\report.txt" 'keeper'; Put "$($c.K)\another" 'duplicate'
    Put "$($c.Q)\a\duplicate" 'existing Q'
    Put "$($c.T)\a\duplicate" 'duplicate'; Put "$($c.T)\report.txt" 'incoming'
    Put "$($c.T)\deep\nested\unique" 'unique'; Put "$($c.T)\other\unique" 'unique'
    [IO.Directory]::CreateDirectory("$($c.T)\empty") | Out-Null
    $k=Snapshot $c.K; $t=Snapshot $c.T; $q=Snapshot $c.Q
    Forward $c $operation
    Check ([IO.File]::Exists($c.Log)) 'explicit log retained'
    Recover $c
    Check ((Snapshot $c.K) -eq $k) "$operation restores K"
    Check ((Snapshot $c.T) -eq $t) "$operation restores T names, content and empty directories"
    Check ((Snapshot $c.Q) -eq $q) "$operation restores Q"
    Recover $c
    Check ((Snapshot $c.T) -eq $t) 'repeated recovery is idempotent'
}

$c=Case 'new-Q'; $c.Q=Join-Path $c.Q 'created\quarantine'
Put "$($c.K)\copy" 'duplicate'; Put "$($c.T)\dir\file" 'duplicate'
$before=Snapshot $c.T; Forward $c; Recover $c
Check ((Snapshot $c.T) -eq $before) 'restore T after Q root creation'
Check (-not [IO.Directory]::Exists($c.Q)) 'new Q root removed'
Check (-not [IO.Directory]::Exists((Split-Path $c.Q))) 'new Q ancestors removed'
Recover $c

$c=Case 'existing-log'; Put $c.Log 'do not overwrite'; Forward $c 'merge' $false
Check ([IO.File]::ReadAllText($c.Log) -eq 'do not overwrite') 'existing log never overwritten'
$c=Case 'inside-log'; $c.Log=Join-Path $c.T 'transaction.log'; Forward $c 'merge' $false
Check (-not [IO.File]::Exists($c.Log)) 'log inside T rejected before creation'

$c=Case 'occupied-original'; Put "$($c.T)\a" 'first'; Put "$($c.T)\z" 'second'
Forward $c; Put "$($c.T)\a" 'new occupant'; $k=Snapshot $c.K; $t=Snapshot $c.T
Recover $c $false
Check ((Snapshot $c.K) -eq $k -and (Snapshot $c.T) -eq $t) 'occupied T preflight prevents all undo operations'

$c=Case 'locked'; Put "$($c.T)\a" 'first'; Put "$($c.T)\z" 'second'; Forward $c
$lock=[IO.File]::Open("$($c.K)\a",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try { Recover $c $false } finally { $lock.Dispose() }
Check ([IO.File]::Exists("$($c.K)\z") -and -not [IO.File]::Exists("$($c.T)\z")) 'locked recovery file aborts before any move'
Recover $c

$c=Case 'replaced-destination'; Put "$($c.T)\file" 'first'; Forward $c
[IO.File]::Move("$($c.K)\file","$($c.K)\saved-original")
Put "$($c.K)\file" 'other'; Recover $c $false
Check ([IO.File]::ReadAllText("$($c.K)\file") -eq 'other') 'replaced destination preserved'

$c=Case 'inferred-rename'; Put "$($c.T)\file" 'first'; Forward $c
Truncate-After $c 'BEGIN_MOVE'
[IO.File]::AppendAllText($c.Log,'{"event":',[Text.UTF8Encoding]::new($false))
Recover $c
Check ([IO.File]::ReadAllText("$($c.T)\file") -eq 'first') 'rename inferred after lost completion checkpoint'
Recover $c

$c=Case 'foreign-created-dir'; Put "$($c.T)\dir\file" 'first'; Forward $c
Put "$($c.K)\dir\foreign" 'foreign'; $k=Snapshot $c.K
Recover $c $false
Check ((Snapshot $c.K) -eq $k) 'unrecorded new content refuses directory cleanup before undo'

$c=Case 'bad-log'; Put "$($c.T)\file" 'first'; Forward $c
[IO.File]::AppendAllText($c.Log,"not-json`n",[Text.UTF8Encoding]::new($false))
Recover $c $false
Check ([IO.File]::Exists("$($c.K)\file")) 'malformed complete record refuses recovery'

if ([IO.Path]::GetPathRoot($env:TEMP) -ne [IO.Path]::GetPathRoot($TestRoot)) {
    $c=Case 'cross-volume'
    $external=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('filemerge-recovery-test-'+[Guid]::NewGuid().ToString('N'))))
    $c.K=Join-Path $external 'K'; $c.Q=Join-Path $external 'Q'
    [IO.Directory]::CreateDirectory($c.K) | Out-Null; [IO.Directory]::CreateDirectory($c.Q) | Out-Null
    try {
        Put "$($c.K)\copy" 'duplicate'; Put "$($c.T)\dir\dupe" 'duplicate'; Put "$($c.T)\unique" ('bytes '*10000)
        $k=Snapshot $c.K; $t=Snapshot $c.T; $q=Snapshot $c.Q
        Forward $c; Recover $c
        Check ((Snapshot $c.K) -eq $k -and (Snapshot $c.T) -eq $t -and (Snapshot $c.Q) -eq $q) 'real cross-volume undo restores all trees'
        Recover $c
        Truncate-After $c 'UNDO_COPIED'; Recover $c
        Check ((Snapshot $c.T) -eq $t) 'cross-volume recovery inferred from durable copy identity'
    } finally {
        $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\filemerge-recovery-test-'
        if (-not $external.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
        Remove-Item -LiteralPath $external -Recurse -Force
    }
} else { Write-Host 'SKIP: real cross-volume recovery; TEMP shares the test volume.' }
Write-Host "Passed $checks transaction/recovery checks."
