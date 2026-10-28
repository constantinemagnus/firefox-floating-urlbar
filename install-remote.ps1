# One-command installer for Windows (no Git checkout needed).
# Paste this in PowerShell; it downloads one archive of main, runs install.ps1,
# and cleans up:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm -ErrorAction Stop https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1)))"
#
# Override the archive with $env:FIREFOX_FLOATING_URLBAR_URL (mostly useful for tests).
$ErrorActionPreference = 'Stop'

$temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-remote-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host 'Downloading installer files...'
    # One archive keeps every file from the same commit, without GitHub API rate limits.
    $url = if ($env:FIREFOX_FLOATING_URLBAR_URL) { $env:FIREFOX_FLOATING_URLBAR_URL }
           else { 'https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/zip/refs/heads/main' }
    $archive = Join-Path $temp 'repo.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri $url -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $temp
    $root = Get-ChildItem -LiteralPath $temp -Directory |
        Where-Object { $_.Name -like 'firefox-floating-urlbar*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') -PathType Leaf) } |
        Select-Object -First 1
    if (-not $root) { throw 'Unexpected repository archive layout.' }
    $directory = $root.FullName
    $global:LASTEXITCODE = 0
    & (Join-Path $directory 'install.ps1') @args
    exit $global:LASTEXITCODE
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
