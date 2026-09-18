param([int]$BroadCount = 3000, [int]$Depth = 300, [string]$UncRoot = '')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = Join-Path $PSScriptRoot '../dist/filemerge.exe'
$suite = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../test-results/run-' + [Guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($suite) | Out-Null
$script:checks = 0
function Assert([bool]$condition, [string]$message) {
    $script:checks++
    if (-not $condition) { throw "Assertion failed: $message" }
}
function New-Case([string]$name) {
    $root = Join-Path $suite $name
    foreach ($tree in 'K','T','Q') { [IO.Directory]::CreateDirectory((Join-Path $root $tree)) | Out-Null }
    return @{ K = "$root\K"; T = "$root\T"; Q = "$root\Q" }
}
function Write-File([string]$path, [string]$content) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}
function Invoke-Reconcile($case, [string]$operation = 'merge', [string]$empty = 'keep',
        [string]$links = 'skip', [bool]$success = $true, [int]$parallelism = 3) {
    $cli = @('-keep',$case.K,'-trim',$case.T,'-quarantine',$case.Q,'-operation',$operation,
        '-hash','sha256','-parallelism',"$parallelism",'-collision','rename','-links',$links,
        '-empty-dirs',$empty,'-verify','yes','-log',(Join-Path $suite ('transaction-'+[Guid]::NewGuid().ToString('N')+'.log')))
    $output = & $exe @cli 2>&1
    $code = $LASTEXITCODE
    $output | Out-File (Join-Path $suite ('output-' + $script:checks + '.txt'))
    Assert (($code -eq 0) -eq $success) "exit $code for $operation; output: $output"
    $journalLine = $output | Where-Object { "$_" -like 'Journal: *' } | Select-Object -First 1
    if ($journalLine) {
        $journalPath = "$journalLine".Substring(9)
        $events = @(Get-Content -LiteralPath $journalPath | ForEach-Object { $_ | ConvertFrom-Json })
        $peaks = @($events | Where-Object event -eq 'IO_PEAK')
        foreach ($peak in $peaks) { Assert ($peak.hash_jobs -le $parallelism) 'global I/O bound' }
        return ,$events
    }
    return ,@()
}

try {
$cliCase=New-Case 'cli'
$validCli=@('-keep',$cliCase.K,'-trim',$cliCase.T,'-quarantine',$cliCase.Q,'-operation','plan',
    '-hash','sha256','-parallelism','2','-collision','rename','-links','skip','-empty-dirs','keep','-verify','yes','-log',(Join-Path $suite 'cli.log'))
function Assert-CliFailure([string[]]$arguments, [string]$expected) {
    $text=(& $exe @arguments 2>&1 | Out-String)
    Assert ($LASTEXITCODE -ne 0) "invalid CLI exits nonzero: $expected"
    Assert ($text.Contains('Usage:') -and $text.Contains('filemerge.exe -keep')) 'invalid CLI shows usage'
    Assert ($text.Contains($expected)) "CLI explains error: $expected; got: $text"
    Assert (-not $text.Contains('Journal:')) 'invalid CLI rejected before run state'
}
Assert-CliFailure -arguments @() -expected 'No parameters supplied.'
Assert-CliFailure -arguments @('-bogus') -expected 'Unknown option or unexpected argument "-bogus".'
Assert-CliFailure -arguments @('-keep') -expected 'Missing value for -keep.'
Assert-CliFailure -arguments @('-keep','K','-keep','other') -expected 'Option -keep was supplied more than once.'
Assert-CliFailure -arguments @('-recover') -expected 'Missing value for -recover.'
Assert-CliFailure -arguments @('-recover','transaction.log','-operation','merge') -expected 'Recovery requires exactly -recover'
for ($i=0; $i -lt 11; $i++) {
    $missing=@(for ($j=0; $j -lt $validCli.Count; $j++) { if ($j -ne 2*$i -and $j -ne 2*$i+1) { $validCli[$j] } })
    Assert-CliFailure -arguments $missing -expected "Missing required option(s): $($validCli[2*$i])."
}
foreach ($index in 7,9,11,13,15,17,19) {
    $bad=$validCli.Clone(); $bad[$index]='invalid'
    Assert-CliFailure -arguments $bad -expected "Invalid value `"invalid`" for $($bad[$index-1]); expected"
}
$bad=$validCli.Clone(); $bad[3]=$bad[1]
Assert-CliFailure -arguments $bad -expected 'K, T and Q must be distinct'
$bad=$validCli.Clone(); $bad[1]=Join-Path $cliCase.K 'does-not-exist'
Assert-CliFailure -arguments $bad -expected 'Not a directory:'
foreach ($help in '-h','-help','--help') {
    $text=(& $exe $help 2>&1 | Out-String)
    Assert ($LASTEXITCODE -eq 0 -and $text.Contains('Usage:') -and -not $text.Contains('ERROR:')) 'explicit help succeeds'
}
$c=New-Case 'empty'; $null=Invoke-Reconcile $c
$c=New-Case 'empty-T'; Write-File "$($c.K)\keeper" 'keep'; $null=Invoke-Reconcile $c
Assert ([IO.File]::ReadAllText("$($c.K)\keeper") -eq 'keep') 'empty T preserves K'

$c=New-Case 'plan-trim-merge'
Write-File "$($c.K)\original" 'duplicate'
Write-File "$($c.K)\other-copy" 'duplicate'
Write-File "$($c.T)\nested\different-name" 'duplicate'
Write-File "$($c.T)\original" 'duplicate'
Write-File "$($c.T)\a\one" 'T-only'
Write-File "$($c.T)\b\two" 'T-only'
$events=Invoke-Reconcile $c 'plan'
Assert (@($events | Where-Object event -eq 'PLANNED').Count -eq 4) 'full plan mappings'
Assert (@(Get-ChildItem -LiteralPath $c.T -File -Recurse).Count -eq 4) 'plan does not mutate T'
Assert (@(Get-ChildItem -LiteralPath $c.Q -Recurse).Count -eq 0) 'plan does not mutate Q'
$null=Invoke-Reconcile $c 'trim'
Assert (@(Get-ChildItem -LiteralPath $c.T -File -Recurse).Count -eq 2) 'only K duplicates trimmed'
Assert ([IO.File]::Exists("$($c.Q)\nested\different-name")) 'quarantine keeps relative path'
$null=Invoke-Reconcile $c
Assert ([IO.File]::Exists("$($c.K)\a\one") -and [IO.File]::Exists("$($c.K)\b\two")) 'T-only duplicates both survive merge'

$c=New-Case 'collisions'
foreach ($name in 'a.txt','many.parts.txt','no-extension','.hidden') {
    Write-File "$($c.K)\$name" 'AAAA'
    $stem=[IO.Path]::GetFileNameWithoutExtension($name); $ext=[IO.Path]::GetExtension($name)
    if ($ext -eq $name) { $stem=$name; $ext='' }
    Write-File "$($c.K)\$stem (1)$ext" '1111'
    Write-File "$($c.K)\$stem (2)$ext" '2222'
    Write-File "$($c.T)\$name" 'BBBB'
}
$null=Invoke-Reconcile $c
foreach ($name in 'a (3).txt','many.parts (3).txt','no-extension (3)','.hidden (3)') {
    Assert ([IO.File]::ReadAllText("$($c.K)\$name") -eq 'BBBB') "collision $name"
}
Assert ([IO.File]::ReadAllText("$($c.K)\a.txt") -eq 'AAAA') 'same size/different hash never overwrites'

$c=New-Case 'Q-collision'; Write-File "$($c.K)\x" 'dupe'; Write-File "$($c.T)\x" 'dupe'; Write-File "$($c.Q)\x" 'old'
$null=Invoke-Reconcile $c
Assert ([IO.File]::ReadAllText("$($c.Q)\x") -eq 'old') 'existing Q content preserved'
Assert ([IO.File]::ReadAllText("$($c.Q)\x (1)") -eq 'dupe') 'Q suffix'

$c=New-Case 'unicode and spaces'
Write-File "$($c.T)\資料\résumé 😀.txt" 'Unicode payload'
$null=Invoke-Reconcile $c
Assert ([IO.File]::Exists("$($c.K)\資料\résumé 😀.txt")) 'Unicode path'

foreach ($policy in 'keep','prune') {
    $c=New-Case "empty-$policy"; Write-File "$($c.T)\a\b\file" 'move'
    [IO.Directory]::CreateDirectory("$($c.T)\already-empty") | Out-Null
    $null=Invoke-Reconcile $c 'merge' $policy
    Assert ([IO.Directory]::Exists("$($c.T)\a") -eq ($policy -eq 'keep')) "empty-dir $policy"
    Assert ([IO.Directory]::Exists("$($c.T)\already-empty")) 'pre-existing empty directory retained'
    Assert ([IO.Directory]::Exists($c.T)) 'T root retained'
}

$c=New-Case 'deep'; $path=$c.T
for ($i=0; $i -lt $Depth; $i++) { $path=Join-Path $path 'd' }
Write-File "$path\leaf" 'deep'
$null=Invoke-Reconcile $c 'merge' 'prune'
Assert (@(Get-ChildItem -LiteralPath $c.T).Count -eq 0) 'deep traversal and pruning'

$c=New-Case 'broad'
for ($i=0; $i -lt $BroadCount; $i++) { Write-File "$($c.T)\f$i" 'small' }
$null=Invoke-Reconcile $c 'plan' 'keep' 'skip' $true 8
Assert (@(Get-ChildItem -LiteralPath $c.T -File).Count -eq $BroadCount) 'broad plan leaves files'

$c=New-Case 'locked'
Write-File "$($c.K)\keeper" 'dupe'; Write-File "$($c.T)\a" 'dupe'; Write-File "$($c.T)\z" 'locked'
$lock=[IO.File]::Open("$($c.T)\z",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try { $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false } finally { $lock.Dispose() }
Assert ([IO.File]::Exists("$($c.T)\a") -and [IO.File]::Exists("$($c.T)\z")) 'busy file abort before first move'
Assert (@(Get-ChildItem -LiteralPath $c.Q -Recurse).Count -eq 0) 'busy preflight no quarantine'

$c=New-Case 'readonly'; Write-File "$($c.T)\a" 'okay'; Write-File "$($c.T)\z" 'protected'
[IO.File]::SetAttributes("$($c.T)\z",[IO.FileAttributes]::ReadOnly)
try {
    $null=Invoke-Reconcile $c 'plan' 'keep' 'skip' $true
    Assert (([IO.File]::GetAttributes("$($c.T)\z") -band [IO.FileAttributes]::ReadOnly) -ne 0) 'plan preserves readonly'
    $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $true
    Assert (([IO.File]::GetAttributes("$($c.K)\z") -band [IO.FileAttributes]::ReadOnly) -ne 0) 'merge preserves readonly'
} finally {
    foreach ($path in @("$($c.T)\z","$($c.K)\z")) {
        if ([IO.File]::Exists($path)) { [IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal) }
    }
}

$c=New-Case 'denied-file'; Write-File "$($c.T)\a" 'okay'; Write-File "$($c.T)\z" 'denied'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$savedAcl=Get-Acl -LiteralPath "$($c.T)\z"
$deniedAcl=Get-Acl -LiteralPath "$($c.T)\z"
$deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'ReadData','Deny'))
Set-Acl -LiteralPath "$($c.T)\z" -AclObject $deniedAcl
try { $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false }
finally { Set-Acl -LiteralPath "$($c.T)\z" -AclObject $savedAcl }
Assert ([IO.File]::Exists("$($c.T)\a")) 'ACL denial abort before first move'

$c=New-Case 'readonly-attribute-denied'; Write-File "$($c.T)\a" 'okay'; Write-File "$($c.T)\z" 'readonly'
[IO.File]::SetAttributes("$($c.T)\z",[IO.FileAttributes]::ReadOnly)
$savedAcl=Get-Acl -LiteralPath "$($c.T)\z"
$deniedAcl=Get-Acl -LiteralPath "$($c.T)\z"
$deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'WriteAttributes','Deny'))
Set-Acl -LiteralPath "$($c.T)\z" -AclObject $deniedAcl
try {
    $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false
    Assert ([IO.File]::Exists("$($c.T)\a")) 'attribute denial aborts before first move'
    Assert (([IO.File]::GetAttributes("$($c.T)\z") -band [IO.FileAttributes]::ReadOnly) -ne 0) 'denied preflight does not clear readonly'
} finally {
    Set-Acl -LiteralPath "$($c.T)\z" -AclObject $savedAcl
    [IO.File]::SetAttributes("$($c.T)\z",[IO.FileAttributes]::Normal)
}

$c=New-Case 'denied-directory'; Write-File "$($c.T)\blocked\z" 'denied'
$savedAcl=Get-Acl -LiteralPath "$($c.T)\blocked"
$deniedAcl=Get-Acl -LiteralPath "$($c.T)\blocked"
$deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'ListDirectory','Deny'))
Set-Acl -LiteralPath "$($c.T)\blocked" -AclObject $deniedAcl
try { $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false }
finally { Set-Acl -LiteralPath "$($c.T)\blocked" -AclObject $savedAcl }
Assert ([IO.File]::Exists("$($c.T)\blocked\z")) 'inaccessible directory aborts safely'

$c=New-Case 'inherited-destination-denial'; Write-File "$($c.T)\new\file" 'do not move'
$savedAcl=Get-Acl -LiteralPath $c.K
$deniedAcl=Get-Acl -LiteralPath $c.K
$deniedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $identity,'WriteData','ObjectInherit,ContainerInherit','InheritOnly','Deny'))
Set-Acl -LiteralPath $c.K -AclObject $deniedAcl
try { $null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false }
finally { Set-Acl -LiteralPath $c.K -AclObject $savedAcl }
Assert ([IO.File]::Exists("$($c.T)\new\file")) 'inherited destination denial caught before moves'
Assert (-not [IO.Directory]::Exists("$($c.K)\new")) 'failed destination preparation removes new empty directories'

$c=New-Case 'missing-Q'; Write-File "$($c.K)\copy" 'dupe'; Write-File "$($c.T)\original" 'dupe'
$c.Q=Join-Path $c.Q 'new\quarantine'
$null=Invoke-Reconcile $c 'plan'
Assert (-not [IO.Directory]::Exists($c.Q)) 'plan does not create absent Q'
$null=Invoke-Reconcile $c
Assert ([IO.File]::Exists("$($c.Q)\original")) 'absent Q created at execution'

$c=New-Case 'blocked-parent'; Write-File "$($c.K)\a" 'a file'; Write-File "$($c.T)\a\child" 'incoming'
$null=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false
Assert ([IO.File]::Exists("$($c.T)\a\child")) 'file-vs-directory conflict preflight'

$c=New-Case 'roots'
foreach ($pair in @(@('K','T'),@('K','Q'),@('T','Q'))) {
    $bad=$c.Clone(); $bad[$pair[1]]=$bad[$pair[0]] + '\.'
    $null=Invoke-Reconcile $bad 'plan' 'keep' 'skip' $false
}
foreach ($pair in @(@('K','T'),@('T','K'),@('K','Q'),@('T','Q'),@('Q','K'),@('Q','T'))) {
    $bad=$c.Clone(); $bad[$pair[1]]=Join-Path $bad[$pair[0]] 'nested'
    [IO.Directory]::CreateDirectory($bad[$pair[1]]) | Out-Null
    $null=Invoke-Reconcile $bad 'plan' 'keep' 'skip' $false
}
$alias=Join-Path (Split-Path $c.K) 'alias'
New-Item -ItemType Junction -Path $alias -Target $c.K | Out-Null
$bad=$c.Clone(); $bad.T=$alias
$null=Invoke-Reconcile $bad 'plan' 'keep' 'skip' $false

$c=New-Case 'links'
Write-File "$($c.T)\real\file" 'link payload'
New-Item -ItemType Junction -Path "$($c.T)\real\cycle" -Target $c.T | Out-Null
New-Item -ItemType Junction -Path "$($c.T)\alias" -Target "$($c.T)\real" | Out-Null
$events=Invoke-Reconcile $c 'plan' 'keep' 'follow'
Assert (@($events | Where-Object event -eq 'PLANNED').Count -eq 1) 'cycle/alias visited once'
$null=Invoke-Reconcile $c 'merge' 'keep' 'skip'
Assert ([IO.File]::Exists("$($c.K)\real\file")) 'links skipped while real file moved'

$c=New-Case 'escape'
New-Item -ItemType Junction -Path "$($c.T)\escape" -Target $c.K | Out-Null
$null=Invoke-Reconcile $c 'plan' 'keep' 'follow' $false

# Real cross-volume transfer, when TEMP is on a different volume from this repo.
if ([IO.Path]::GetPathRoot($env:TEMP) -ne [IO.Path]::GetPathRoot($suite)) {
    $c=New-Case 'cross-volume'
    $external=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('folder-merge-cross-test-' + [Guid]::NewGuid().ToString('N'))))
    [IO.Directory]::CreateDirectory($external) | Out-Null
    $c.K=Join-Path $external 'K'; [IO.Directory]::CreateDirectory($c.K) | Out-Null
    Write-File "$($c.T)\file" ('cross-volume payload ' * 10000)
    $original=(Get-FileHash -LiteralPath "$($c.T)\file" -Algorithm SHA256).Hash
    $events=Invoke-Reconcile $c
    Assert ((Get-FileHash -LiteralPath "$($c.K)\file" -Algorithm SHA256).Hash -eq $original) 'real cross-volume SHA256'
    Assert (-not [IO.File]::Exists("$($c.T)\file")) 'cross-volume removes source after verify'
    Assert (@($events | Where-Object event -eq 'DESTINATION_PUBLISHED').Count -eq 1) 'cross-volume publication journal'
    # A sparse file larger than destination free space exercises a real refusal
    # without allocating or reading that many bytes. No counterpart size in K.
    $sparse=Join-Path $c.T 'too-large.bin'
    Write-File $sparse ''
    $null=& fsutil sparse setflag $sparse 2>&1
    if ($LASTEXITCODE -eq 0) {
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($external))
        $stream=[IO.File]::OpenWrite($sparse)
        try { $stream.SetLength($drive.AvailableFreeSpace + 1GB) } finally { $stream.Dispose() }
        Write-File "$($c.T)\a-first" 'still here'
        $events=Invoke-Reconcile $c 'merge' 'keep' 'skip' $false
        Assert ([IO.File]::Exists("$($c.T)\a-first")) 'disk-space refusal precedes first move'
        Assert (-not [IO.File]::Exists("$($c.K)\a-first")) 'disk-space refusal no partial reconciliation'
        Assert (@($events | Where-Object { $_.event -eq 'ERROR' -and $_.message -like '*Insufficient space*' }).Count -gt 0) 'space failure explained'
    } else { Write-Host 'SKIP: sparse-file disk-space integration; sparse files unavailable.' }
    [IO.File]::Delete($sparse)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\folder-merge-cross-test-'
    if (-not $external.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup target' }
    Remove-Item -LiteralPath $external -Recurse -Force
} else { Write-Host 'SKIP: real cross-volume test; TEMP and workspace share a volume. Injected copy tests still run.' }

if ($UncRoot) {
    if (-not $UncRoot.StartsWith('\\')) { throw 'UncRoot must be a UNC path to an existing writable share directory' }
    $uncCaseRoot=Join-Path $UncRoot ('folder-merge-test-' + [Guid]::NewGuid().ToString('N'))
    $c=@{ K="$uncCaseRoot\K"; T="$uncCaseRoot\T"; Q="$uncCaseRoot\Q" }
    foreach ($path in $c.Values) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    Write-File "$($c.T)\資料.txt" 'UNC test'
    $null=Invoke-Reconcile $c
    Assert ([IO.File]::ReadAllText("$($c.K)\資料.txt") -eq 'UNC test') 'UNC merge'
    Write-Host "UNC fixtures: $uncCaseRoot"
} else { Write-Host 'SKIP: live UNC share; use -UncRoot to supply a test location.' }

Write-Host "Passed $script:checks Windows integration checks. Fixtures and output: $suite"
& (Join-Path $PSScriptRoot 'recovery.ps1') -Executable $exe -TestRoot $suite
} finally {
    & (Join-Path $PSScriptRoot 'clean-test-links.ps1') -Root $suite
}
