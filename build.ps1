param([string]$OcamlRoot = 'F:\tools\ocaml', [switch]$Test)
$ErrorActionPreference = 'Stop'
. (Join-Path $OcamlRoot 'activate.ps1')
Push-Location $PSScriptRoot
try {
    $version = & ocamlopt -version
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^5\.5\.') { throw "OCaml 5.5 required; found $version" }
    & dune build --profile release src/main.exe
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
    New-Item -ItemType Directory -Force dist | Out-Null
    Copy-Item -LiteralPath '_build/default/src/main.exe' -Destination 'dist/filemerge.exe' -Force
    if ($Test) {
        & dune runtest --profile release
        if ($LASTEXITCODE -ne 0) { throw 'OCaml tests failed' }
        & (Join-Path $PSScriptRoot 'tests/integration.ps1')
        if (-not $?) { throw 'Integration tests failed' }
    }
    Write-Host "Release executable: $PSScriptRoot\dist\filemerge.exe"
} finally { Pop-Location }
