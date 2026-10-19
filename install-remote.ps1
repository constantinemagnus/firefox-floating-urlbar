# One-command installer for Windows (no Git checkout needed).
# Paste this in PowerShell; it downloads the required files, runs install.ps1,
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
    if ($env:FIREFOX_FLOATING_URLBAR_URL) {
        $archive = Join-Path $temp 'repo.zip'
        Invoke-WebRequest -UseBasicParsing -Uri $env:FIREFOX_FLOATING_URLBAR_URL -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $temp
        $root = Get-ChildItem -LiteralPath $temp -Directory |
            Where-Object { $_.Name -like 'firefox-floating-urlbar*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') -PathType Leaf) } |
            Select-Object -First 1
        if (-not $root) { throw 'Unexpected repository archive layout.' }
        $directory = $root.FullName
    } else {
        Write-Host 'Downloading installer files...'
        # Resolve once so files cannot come from different commits during an update.
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.github.com/repos/constantinemagnus/firefox-floating-urlbar/commits/main' -Headers @{ Accept = 'application/vnd.github.sha' }
        $content = $response.Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        $revision = ([string]$content).Trim()
        if ($revision -notmatch '\A[a-fA-F0-9]{40}\z') { throw 'Invalid repository revision.' }
        $directory = Join-Path $temp 'firefox-floating-urlbar'
        [IO.Directory]::CreateDirectory((Join-Path $directory 'JS')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $directory 'CSS')) | Out-Null
        foreach ($file in @('install.ps1', 'fx-autoconfig.conf', 'JS/replace-new-tab.uc.js', 'CSS/firefox-floating-urlbar.uc.css')) {
            Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/$revision/$file" -OutFile (Join-Path $directory $file)
        }
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $directory 'install.ps1') @args
    exit $global:LASTEXITCODE
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
