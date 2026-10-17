param([string]$Root = (Join-Path $PSScriptRoot '../test-results'))
$ErrorActionPreference = 'Stop'

# Never recurse through a reparse point or delete a junction's target.
$boundary = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../test-results')).TrimEnd('\')
$target = [IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($target -ne $boundary -and -not $target.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Cleanup is restricted to $boundary"
}
if (-not [IO.Directory]::Exists($target)) { return }

# Also reject a supplied root reached through a junction in its ancestry.
$ancestor = $target
while ($ancestor.Length -ge $boundary.Length) {
    if ([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup root/ancestor is a reparse point: $ancestor"
    }
    if ($ancestor -eq $boundary) { break }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}

$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($target)
$removed = 0
$cleared = 0
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    # Recovery tests intentionally restore directory readonly flags. Clear them
    # only after assertions, so Git can remove the retained test fixtures.
    $directoryAttributes = [IO.File]::GetAttributes($directory)
    if ($directoryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup directory became a reparse point: $directory"
    }
    if ($directoryAttributes -band [IO.FileAttributes]::ReadOnly) {
        [IO.File]::SetAttributes($directory, $directoryAttributes -band (-bnot [IO.FileAttributes]::ReadOnly))
        $cleared++
    }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
        $attributes = [IO.File]::GetAttributes($entry)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($attributes -band [IO.FileAttributes]::Directory) {
                [IO.Directory]::Delete($entry, $false)
            } else {
                [IO.File]::Delete($entry)
            }
            $removed++
        } elseif ($attributes -band [IO.FileAttributes]::Directory) {
            $pending.Push($entry)
        }
    }
}
Write-Host "Removed $removed test link(s) without following their targets."
Write-Host "Cleared readonly on $cleared test directories."
