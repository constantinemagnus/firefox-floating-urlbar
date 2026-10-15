# One-command installer for Windows (no Git checkout needed).
# Paste this in PowerShell; it downloads this repository, runs install.ps1,
# and cleans up:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1 | iex"
#
# Override the archive with $env:FIREFOX_FLOATING_URLBAR_URL (mostly useful for tests).
$ErrorActionPreference = 'Stop'
$repo = $env:FIREFOX_FLOATING_URLBAR_URL
if (-not $repo) { $repo = 'https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/zip/refs/heads/main' }

$temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-remote-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $archive = Join-Path $temp 'repo.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $repo -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $temp
    $root = Get-ChildItem -LiteralPath $temp -Directory |
        Where-Object { $_.Name -like 'firefox-floating-urlbar-*' } |
        Select-Object -First 1
    if (-not $root) { throw 'Unexpected repository archive layout.' }
    $global:LASTEXITCODE = 0
    & "$($root.FullName)\install.ps1" @args
    exit $global:LASTEXITCODE
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
