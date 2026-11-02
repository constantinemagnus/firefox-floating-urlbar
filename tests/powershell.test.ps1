# install.ps1 and install-remote.ps1 against offline fixtures. No real profile,
# Firefox, network or UAC prompt is used.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-tests-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temp) | Out-Null
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA
$originalRemoteArchive = $env:FIREFOX_FLOATING_URLBAR_URL

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-Rejected([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    Assert-That $rejected $Message
}
function Test-SameFile([string]$First, [string]$Second) {
    return (Test-Path -LiteralPath $Second) -and (Get-FileHash -LiteralPath $First).Hash -eq (Get-FileHash -LiteralPath $Second).Hash
}

try {
    . "$repo/install.ps1"
    $env:APPDATA = Join-Path $temp 'appdata'
    $env:LOCALAPPDATA = Join-Path $temp 'localappdata'
    $interpreter = (Get-Process -Id $PID).Path

    # Builds a fixture snapshot for $Commit and pins the installer to it.
    function New-Snapshot([string]$Commit) {
        $fixture = Join-Path $temp "source-$Commit/fx-autoconfig-$Commit"
        [IO.Directory]::CreateDirectory("$fixture/program/defaults/pref") | Out-Null
        [IO.Directory]::CreateDirectory("$fixture/profile/chrome/utils") | Out-Null
        Set-Content "$fixture/LICENSE" 'fixture MPL-2.0 license'
        Set-Content "$fixture/program/config.js" "// fixture startup $Commit"
        Set-Content "$fixture/program/defaults/pref/config-prefs.js" 'pref("general.config.filename", "config.js");'
        foreach ($file in @('chrome.manifest') + $AutoconfigModules) {
            Set-Content "$fixture/profile/chrome/utils/$file" "fixture $Commit $file"
        }
        $script:archive = Join-Path $temp "$Commit.zip"
        Compress-Archive -LiteralPath $fixture -DestinationPath $script:archive
        $script:AutoconfigPin = @{ AUTOCONFIG_COMMIT = $Commit; AUTOCONFIG_ZIP_SHA256 = (Get-FileHash -LiteralPath $script:archive).Hash }
        $script:snapshot = $fixture
    }
    $script:downloads = @()
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec) {
        $script:downloads += $Uri
        Copy-Item -LiteralPath $script:archive -Destination $OutFile
    }
    function New-Case([string]$Name) {
        $script:ProfilePath = Join-Path $temp "$Name/profile with spaces"
        $script:FirefoxDirectory = Join-Path $temp "$Name/Mozilla Firefox"
        [IO.Directory]::CreateDirectory($script:ProfilePath) | Out-Null
        [IO.Directory]::CreateDirectory($script:FirefoxDirectory) | Out-Null
        Set-Content "$script:ProfilePath/prefs.js" 'unchanged prefs'
        Set-Content "$script:FirefoxDirectory/firefox.exe" 'fixture executable'
        $script:downloads = @()
        $script:utils = Join-Path $script:ProfilePath 'chrome/utils'
    }
    function Install-Case { $script:Uninstall = $false; $script:RemoveAutoconfig = $false; $script:RemoveSharedAutoconfig = $false; Invoke-FloatingUrlbarInstall }
    function Uninstall-Case([switch]$Shared) {
        $script:Uninstall = $true; $script:RemoveAutoconfig = $true; $script:RemoveSharedAutoconfig = $Shared.IsPresent
        try { Invoke-FloatingUrlbarInstall } finally { $script:Uninstall = $false }
    }
    # Cleanup prompts must never wait for input during tests.
    function Read-CleanupConfirmation { return $false }
    New-Snapshot 'first'

    # Catches: a broken profiles.ini parser (relative vs absolute paths, BOM-less
    # UTF-8 names) or a missing Profiles/ fallback installing into the wrong folder.
    & {
        $root = Join-Path $temp 'profiles root'
        $relative = Join-Path $root ('relative ' + [char]0xE9)
        $absolute = Join-Path $temp 'absolute profile'
        foreach ($path in @($relative, $absolute, "$root/uninitialized")) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        foreach ($path in @($relative, $absolute)) { Set-Content "$path/prefs.js" 'fixture' }
        [IO.File]::WriteAllText("$root/profiles.ini", "[Profile0]`nName=Relative`nIsRelative=1`nPath=$(Split-Path $relative -Leaf)`n[Profile1]`nName=Absolute`nIsRelative=0`nPath=$absolute`n[Profile2]`nName=Unused`nPath=uninitialized`n", (New-Object Text.UTF8Encoding($false)))
        $profiles = @(Get-FirefoxProfiles $root)
        Assert-That ($profiles.Count -eq 2 -and $profiles[0].Path -eq $relative -and $profiles[1].Path -eq $absolute) 'profiles.ini parsed incorrectly'
        Remove-Item "$root/profiles.ini"
        $nested = Join-Path $root 'Profiles/nested'
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        Set-Content "$nested/prefs.js" 'fixture'
        Assert-That (@(Get-FirefoxProfiles $root).Path -contains $nested) 'Profiles/ fallback missed a folder'
    }

    # Catches: the remembered profile from the last install being lost from the menu,
    # duplicated by a trailing separator, or not offered as the Enter default.
    & {
        $root = Join-Path $temp 'menu root'
        foreach ($name in @('one', 'two')) {
            [IO.Directory]::CreateDirectory("$root/$name") | Out-Null
            Set-Content "$root/$name/prefs.js" 'fixture'
        }
        Set-Content "$root/profiles.ini" "[Profile0]`nName=One`nPath=one`n[Profile1]`nName=Two`nPath=two"
        $script:menuRows = 0
        function Write-Host([string]$Object) { $script:menuRows++ }
        function Read-Host([string]$Prompt) { return '' }
        Assert-That ((Select-FirefoxProfile $root "$root/two/") -eq (Join-Path $root 'two') -and $script:menuRows -eq 2) 'remembered profile not the single default row'
        $outside = Join-Path $temp 'absolute profile'
        Assert-That ((Select-FirefoxProfile $root $outside) -eq $outside) 'remembered profile outside the root lost'
    }

    # Catches: compatibility.ini not locating Firefox, or an explicit directory not winning.
    & {
        New-Case 'locate'
        Set-Content "$ProfilePath/compatibility.ini" "[Compatibility]`nLastPlatformDir=$FirefoxDirectory"
        Assert-That ((Find-FirefoxDirectory $ProfilePath '') -eq $FirefoxDirectory) 'LastPlatformDir ignored'
        $explicit = Join-Path $temp 'explicit Firefox'
        [IO.Directory]::CreateDirectory($explicit) | Out-Null
        Set-Content "$explicit/firefox.exe" 'fixture'
        Assert-That ((Find-FirefoxDirectory $ProfilePath $explicit) -eq $explicit) 'explicit Firefox directory did not win'
    }

    # Catches: a fresh install missing any piece Firefox needs (startup files, loader,
    # payloads, saved profile), fetching the wrong snapshot, or dropping the MPL notice.
    New-Case 'fresh'
    Install-Case
    Assert-That (($script:downloads -join ',') -eq 'https://codeload.github.com/MrOtherGuy/fx-autoconfig/zip/first') 'wrong snapshot URL'
    Assert-That (Test-SameFile "$snapshot/program/config.js" "$FirefoxDirectory/config.js") 'config.js missing'
    Assert-That (Test-SameFile "$snapshot/program/defaults/pref/config-prefs.js" "$FirefoxDirectory/defaults/pref/config-prefs.js") 'config-prefs.js missing'
    Assert-That (Test-Path "$FirefoxDirectory/.floating-urlbar-autoconfig") 'shared files not marked as ours'
    Assert-That (Test-SameFile "$snapshot/profile/chrome/utils/boot.sys.mjs" "$utils/boot.sys.mjs") 'loader missing'
    Assert-That ((Get-Content "$utils/.floating-urlbar-source") -eq 'first') 'loader commit not recorded'
    Assert-That (Test-SameFile "$snapshot/LICENSE" "$utils/fx-autoconfig.LICENSE") 'upstream license missing'
    Assert-That (Test-SameFile "$repo/JS/replace-new-tab.uc.js" "$ProfilePath/chrome/JS/replace-new-tab.uc.js") 'script missing'
    Assert-That (Test-SameFile "$repo/CSS/firefox-floating-urlbar.uc.css" "$ProfilePath/chrome/CSS/firefox-floating-urlbar.uc.css") 'stylesheet missing'
    Assert-That ((Get-Content "$env:APPDATA/firefox-floating-urlbar/profile") -eq $ProfilePath) 'profile not remembered'

    # Catches: reinstalling the same pin downloading again.
    Install-Case
    Assert-That ($script:downloads.Count -eq 1) 'unchanged reinstall downloaded again'

    # Catches: a new pin not updating our loader and our shared startup files.
    New-Snapshot 'second'
    Install-Case
    Assert-That ((Get-Content "$utils/.floating-urlbar-source") -eq 'second') 'loader not upgraded'
    Assert-That (Test-SameFile "$snapshot/program/config.js" "$FirefoxDirectory/config.js") 'owned config.js not upgraded'

    # Catches: an edited payload being removed without a backup, or the saved
    # profile surviving its uninstall.
    Set-Content "$ProfilePath/chrome/JS/replace-new-tab.uc.js" 'local edit'
    $script:Uninstall = $true
    try { Invoke-FloatingUrlbarInstall } finally { $script:Uninstall = $false }
    $backups = @(Get-ChildItem "$ProfilePath/chrome/JS" -Filter 'replace-new-tab.uc.js.bak-*')
    Assert-That ($backups.Count -eq 1 -and (Get-Content $backups[0].FullName) -eq 'local edit') 'edited payload not backed up'
    Assert-That (-not (Test-Path "$ProfilePath/chrome/JS/replace-new-tab.uc.js")) 'payload not removed'
    Assert-That (-not (Test-Path "$env:APPDATA/firefox-floating-urlbar/profile")) 'saved profile kept after uninstall'

    # Catches: a tampered or wrong download being installed.
    New-Case 'checksum'
    $pinned = $script:archive
    # A well-formed archive, so only the checksum can stop it.
    $tampered = Join-Path $temp 'tampered/fx-autoconfig-second'
    Copy-Item -Recurse $snapshot $tampered
    Set-Content "$tampered/program/config.js" '// tampered'
    $script:archive = Join-Path $temp 'tampered.zip'
    Compress-Archive -LiteralPath $tampered -DestinationPath $script:archive
    Assert-Rejected { Install-Case } 'checksum mismatch accepted'
    Assert-That (-not (Test-Path "$FirefoxDirectory/config.js") -and -not (Test-Path "$utils/boot.sys.mjs")) 'files written after checksum mismatch'
    $script:archive = $pinned

    # Catches: overwriting, or later deleting, a loader the user installed themselves.
    New-Case 'external'
    [IO.Directory]::CreateDirectory($utils) | Out-Null
    Set-Content "$utils/boot.sys.mjs" 'their loader'
    Set-Content "$utils/chrome.manifest" 'their manifest'
    Install-Case
    Assert-That ($script:downloads.Count -eq 0 -and (Get-Content "$utils/boot.sys.mjs") -eq 'their loader') 'external loader replaced'
    Uninstall-Case -Shared
    Assert-That ((Get-Content "$utils/boot.sys.mjs") -eq 'their loader') 'uninstall removed external loader'

    # Catches: overriding another browser's AutoConfig (LibreWolf ships its own).
    New-Case 'foreign'
    [IO.Directory]::CreateDirectory("$FirefoxDirectory/defaults/pref") | Out-Null
    Set-Content "$FirefoxDirectory/defaults/pref/librewolf.js" 'pref("general.config.filename", "librewolf.cfg");'
    Assert-Rejected { Install-Case } 'foreign AutoConfig accepted'
    Assert-That (-not (Test-Path "$FirefoxDirectory/config.js")) 'wrote config.js beside foreign AutoConfig'

    # Catches: replacing a startup file someone else created.
    New-Case 'unowned'
    Set-Content "$FirefoxDirectory/config.js" '// their config'
    Assert-Rejected { Install-Case } 'unowned config.js replaced'
    Assert-That ((Get-Content "$FirefoxDirectory/config.js") -eq '// their config') 'unowned config.js changed'

    # Catches: matching startup files we did not create being marked as ours, which
    # would let uninstall remove them.
    New-Case 'adopted'
    Copy-Item "$snapshot/program/config.js" "$FirefoxDirectory/config.js"
    Install-Case
    Assert-That (-not (Test-Path "$FirefoxDirectory/.floating-urlbar-autoconfig")) 'adopted shared files marked as ours'

    # Catches: an access error (also when .NET wraps it) not elevating, an elevation
    # command that does not parse or quote an apostrophe, profile writes inside the
    # elevated command, and a cancelled prompt being treated as success.
    & {
        $originalStartup = (Get-Command Install-StartupFiles).ScriptBlock
        New-Case "elevation user's $([char]0x2019)case"
        function Install-StartupFiles {
            throw [Management.Automation.MethodInvocationException]::new('fixture wrapped', [UnauthorizedAccessException]::new('fixture'))
        }
        $script:elevations = 0
        function Start-Process([string]$FilePath, [string]$Verb, [switch]$Wait, [switch]$PassThru, [string[]]$ArgumentList) {
            $script:elevations++
            Assert-That ($Verb -eq 'RunAs' -and $Wait -and $PassThru) 'elevation did not wait for its result'
            $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($decoded, [ref]$null, [ref]$parseErrors)
            Assert-That ($parseErrors.Count -eq 0) 'elevation command does not parse'
            $values = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true).Value)
            Assert-That ($values -contains $FirefoxDirectory) 'elevation lost the Firefox directory'
            Assert-That ($decoded.Contains('-StartupOnly') -and -not $decoded.Contains('-ProfilePath')) 'elevation included profile writes'
            & $originalStartup "$snapshot/program" $FirefoxDirectory
            return [pscustomobject]@{ ExitCode = 0 }
        }
        Install-Case
        Assert-That ($script:elevations -eq 1 -and (Test-Path "$FirefoxDirectory/config.js") -and (Test-Path "$utils/boot.sys.mjs")) 'install did not finish after elevation'
        New-Case 'cancelled elevation'
        function Start-Process { return [pscustomobject]@{ ExitCode = 1 } }
        Assert-Rejected { Install-Case } 'cancelled elevation accepted'
        Assert-That (-not (Test-Path "$ProfilePath/chrome")) 'cancelled elevation wrote profile files'
    }

    # Catches: the elevated entry point (-StartupOnly) failing as a real child process,
    # or installing startup files without checking the archive.
    & {
        $childScript = Join-Path $temp 'child-script'
        $childFirefox = Join-Path $temp 'child-Firefox'
        foreach ($path in @($childScript, $childFirefox)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        Copy-Item "$repo/install.ps1" "$childScript/install.ps1"
        Set-Content "$childFirefox/firefox.exe" 'fixture'
        Set-Content "$childScript/fx-autoconfig.conf" "AUTOCONFIG_COMMIT=second`nAUTOCONFIG_ZIP_SHA256=0000"
        # Windows PowerShell 5.1 turns redirected native stderr into a terminating error under 'Stop'.
        $ErrorActionPreference = 'Continue'
        & $interpreter -NoProfile -NonInteractive -File "$childScript/install.ps1" -StartupOnly -FirefoxDirectory $childFirefox -ArchivePath $script:archive 2>$null
        $ErrorActionPreference = 'Stop'
        Assert-That ($LASTEXITCODE -ne 0 -and -not (Test-Path "$childFirefox/config.js")) 'elevated child skipped the checksum'
        Set-Content "$childScript/fx-autoconfig.conf" "AUTOCONFIG_COMMIT=second`nAUTOCONFIG_ZIP_SHA256=$($AutoconfigPin.AUTOCONFIG_ZIP_SHA256)"
        & $interpreter -NoProfile -NonInteractive -File "$childScript/install.ps1" -StartupOnly -FirefoxDirectory $childFirefox -ArchivePath $script:archive
        Assert-That ($LASTEXITCODE -eq 0 -and (Test-Path "$childFirefox/defaults/pref/config-prefs.js")) 'elevated child failed'
    }

    # Catches: optional cleanup breaking other user scripts that rely on the loader.
    New-Case 'shared other'
    Install-Case
    Set-Content "$ProfilePath/chrome/other.uc.js" '// another mod'
    Assert-Rejected { Uninstall-Case } 'cleanup ignored another customization'
    Assert-That (Test-Path "$utils/boot.sys.mjs") 'loader removed despite another customization'

    # Catches: full cleanup leaving our files behind, or removing the profile itself.
    New-Case 'cleanup'
    Install-Case
    Uninstall-Case -Shared
    foreach ($path in @($utils, "$FirefoxDirectory/config.js", "$FirefoxDirectory/defaults/pref/config-prefs.js", "$FirefoxDirectory/.floating-urlbar-autoconfig")) {
        Assert-That (-not (Test-Path -LiteralPath $path)) "cleanup left $path"
    }
    Assert-That ((Get-Content "$ProfilePath/prefs.js") -eq 'unchanged prefs') 'cleanup changed prefs'

    # Catches: a roaming profile's cache under LOCALAPPDATA being missed, or another
    # profile's cache being cleared.
    & {
        function Get-Process { }
        $roaming = Join-Path $env:APPDATA 'Mozilla/Firefox/Profiles/cache.default'
        $local = Join-Path $env:LOCALAPPDATA 'Mozilla/Firefox/Profiles/cache.default/startupCache'
        $other = Join-Path $env:LOCALAPPDATA 'Mozilla/Firefox/Profiles/other.default/startupCache'
        foreach ($path in @($roaming, $local, $other)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        Clear-StartupCache $roaming
        Assert-That (-not (Test-Path $local) -and (Test-Path $other)) 'wrong startup cache cleared'
    }

    # Remote launcher: forward options, discard stale status, and clean up on failure.
    $remoteFixture = Join-Path $temp 'remote-fixture/firefox-floating-urlbar-main'
    [IO.Directory]::CreateDirectory($remoteFixture) | Out-Null
    $remoteTrace = Join-Path $temp 'remote-trace.json'
    Set-Content -LiteralPath "$remoteFixture/install.ps1" -Value @'
param([string]$ProfilePath, [switch]$Uninstall, [switch]$RemoveSharedAutoconfig)
@{ ProfilePath = $ProfilePath; Uninstall = $Uninstall.IsPresent; Cleanup = $RemoveSharedAutoconfig.IsPresent; Directory = $PSScriptRoot } |
    ConvertTo-Json | Set-Content -LiteralPath $remoteTrace
if ($remoteExit) { exit $remoteExit }
'@
    $remoteArchive = Join-Path $temp 'remote.zip'
    Compress-Archive -LiteralPath $remoteFixture -DestinationPath $remoteArchive
    $env:FIREFOX_FLOATING_URLBAR_URL = 'https://example.invalid/fixture.zip'
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec) {
        Assert-That ($TimeoutSec -eq 180) 'remote archive timeout missing'
        Copy-Item -LiteralPath $remoteArchive -Destination $OutFile
    }
    foreach ($remoteExit in @(0, 9)) {
        $global:LASTEXITCODE = 37
        & "$repo/install-remote.ps1" -Uninstall -ProfilePath 'temporary profile with spaces'
        Assert-That ($global:LASTEXITCODE -eq $remoteExit) 'remote launcher returned the wrong exit status'
        $trace = Get-Content -LiteralPath $remoteTrace -Raw | ConvertFrom-Json
        Assert-That ($trace.Uninstall -and $trace.ProfilePath -eq 'temporary profile with spaces') 'remote arguments were not forwarded'
        Assert-That (-not (Test-Path -LiteralPath $trace.Directory)) 'remote launcher left temporary files'
    }
    Remove-Item -LiteralPath "$remoteFixture/install.ps1"
    $manualArchive = Join-Path $temp 'manual.zip'
    Set-Content -LiteralPath "$remoteFixture/README.md" 'manual payload'
    Compress-Archive -LiteralPath $remoteFixture -DestinationPath $manualArchive
    $remoteArchive = $manualArchive
    $layoutError = ''
    try { & "$repo/install-remote.ps1" } catch { $layoutError = $_.Exception.Message }
    Assert-That ($layoutError -eq 'Unexpected repository archive layout.') 'manual ZIP did not produce layout error'
    # Restore the stub for the remaining lean-download tests.
    Expand-Archive -LiteralPath "$temp/remote.zip" -DestinationPath "$temp/restored-remote"
    Copy-Item -LiteralPath "$temp/restored-remote/firefox-floating-urlbar-main/install.ps1" -Destination "$remoteFixture/install.ps1"

    # Exercise both shells: caller interpolation, then a real child with mocked HTTP.
    $readme = Get-Content -LiteralPath "$repo/README.md" -Raw
    $pasteCommand = [regex]::Match($readme, 'powershell -NoProfile -ExecutionPolicy Bypass -Command "[^"]+"').Value
    Assert-That ($pasteCommand -ne '') 'Windows installation command missing'
    foreach ($downloadMode in @('success', 'failure')) {
        $requestTrace = Join-Path $temp "initial-$downloadMode-request"
        $executionTrace = Join-Path $temp "initial-$downloadMode-executed"
        $mockModule = Join-Path $temp "initial-$downloadMode.psm1"
        $mockSource = @'
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri)
    [IO.File]::WriteAllText('__REQUEST__', $Uri)
    if ('__MODE__' -eq 'failure') { Write-Error 'fixture initial download failure'; return }
    return "[IO.File]::WriteAllText('__EXECUTED__', 'installed'); exit 0"
}
Export-ModuleMember -Function Invoke-RestMethod
'@
        $mockSource = $mockSource.Replace('__REQUEST__', $requestTrace.Replace("'", "''")).Replace('__EXECUTED__', $executionTrace.Replace("'", "''")).Replace('__MODE__', $downloadMode)
        Set-Content -LiteralPath $mockModule -Value $mockSource
        # Only substitute the executable; preserve the README's native argument syntax.
        $invocation = $pasteCommand.Replace('powershell -NoProfile', "& '$($interpreter.Replace("'", "''"))' -NoProfile")
        $invocation = $invocation.Replace('-Command "', "-Command `"Import-Module '$($mockModule.Replace("'", "''"))' -Force -ErrorAction Stop; if ((Get-Command irm).ResolvedCommand.ModuleName -ne 'initial-$downloadMode') { throw 'HTTP mock is not active' }; ")
        $caller = Join-Path $temp "initial-$downloadMode-caller.ps1"
        Set-Content -LiteralPath $caller -Value ("`$ErrorActionPreference = 'Continue'`n" + $invocation + "`nexit `$LASTEXITCODE")
        & $interpreter -NoProfile -NonInteractive -File $caller
        Assert-That ((Test-Path -LiteralPath $requestTrace) -and
            (Get-Content -LiteralPath $requestTrace) -eq 'https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/main/install-remote.ps1') 'documented command did not call the download mock with the expected URL'
        if ($downloadMode -eq 'success') {
            Assert-That ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $executionTrace)) 'documented command did not execute the downloaded installer'
        } else {
            Assert-That ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $executionTrace)) 'initial download failure reported success or ran the installer'
        }
    }

    $env:FIREFOX_FLOATING_URLBAR_URL = $null
    $remoteExit = 0
    $global:floatingUrlbarRemoteDownloads = @()
    $global:floatingUrlbarRemoteMode = 'archive'
    $global:floatingUrlbarRemoteArchive = Join-Path $temp 'remote.zip'
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec) {
        Assert-That ($TimeoutSec -eq 180) 'remote request timeout missing'
        $global:floatingUrlbarRemoteDownloads += $Uri
        if ($global:floatingUrlbarRemoteMode -eq 'download-error') { throw 'fixture download failure' }
        if ($global:floatingUrlbarRemoteMode -eq 'corrupt-archive') { Set-Content -LiteralPath $OutFile -Value 'not an archive'; return }
        Copy-Item -LiteralPath $global:floatingUrlbarRemoteArchive -Destination $OutFile
    }
    foreach ($mode in @('archive', 'download-error', 'corrupt-archive')) {
        $global:floatingUrlbarRemoteMode = $mode
        $global:floatingUrlbarRemoteDownloads = @()
        Remove-Item -LiteralPath $remoteTrace -ErrorAction SilentlyContinue
        $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'floating-urlbar-remote-*' | ForEach-Object Name)
        if ($mode -eq 'archive') {
            & "$repo/install-remote.ps1" -Uninstall -RemoveSharedAutoconfig -ProfilePath 'temporary profile with spaces'
            $trace = Get-Content -LiteralPath $remoteTrace -Raw | ConvertFrom-Json
            Assert-That ($trace.Cleanup -and $trace.Uninstall -and $trace.ProfilePath -eq 'temporary profile with spaces') 'default launcher lost cleanup arguments'
            Assert-That (($global:floatingUrlbarRemoteDownloads -join ',') -eq 'https://codeload.github.com/constantinemagnus/firefox-floating-urlbar/zip/refs/heads/main') 'default launcher downloaded unexpected URLs'
        } else {
            Assert-Rejected { & "$repo/install-remote.ps1" } "accepted $mode"
            Assert-That (-not (Test-Path -LiteralPath $remoteTrace)) "executed installer after $mode"
        }
        $after = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'floating-urlbar-remote-*' | ForEach-Object Name)
        Assert-That (($before -join ',') -eq ($after -join ',')) "$mode remote launcher left temporary files"
    }
    # Execute the actual downloaded script against a temporary external loader.
    $global:floatingUrlbarRemoteMode = 'archive'
    $realSource = Join-Path $temp 'remote-real-source/firefox-floating-urlbar-main'
    foreach ($file in @('install.ps1', 'fx-autoconfig.conf', 'JS/replace-new-tab.uc.js', 'CSS/firefox-floating-urlbar.uc.css')) {
        [IO.Directory]::CreateDirectory((Split-Path (Join-Path $realSource $file) -Parent)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $realSource $file)
    }
    $global:floatingUrlbarRemoteArchive = Join-Path $temp 'remote-real.zip'
    Compress-Archive -LiteralPath $realSource -DestinationPath $global:floatingUrlbarRemoteArchive
    $realProfile = Join-Path $temp 'remote-real/profile with spaces'
    $realFirefox = Join-Path $temp 'remote-real/Firefox'
    [IO.Directory]::CreateDirectory("$realProfile/chrome/utils") | Out-Null
    [IO.Directory]::CreateDirectory("$realFirefox/defaults/pref") | Out-Null
    Set-Content -LiteralPath "$realProfile/prefs.js" 'preserve preferences'
    Set-Content -LiteralPath "$realProfile/chrome/utils/boot.sys.mjs" 'existing external loader'
    Set-Content -LiteralPath "$realProfile/chrome/utils/chrome.manifest" 'existing manifest'
    Set-Content -LiteralPath "$realFirefox/firefox.exe" 'fixture'
    Set-Content -LiteralPath "$realFirefox/config.js" '// existing startup'
    Set-Content -LiteralPath "$realFirefox/defaults/pref/config-prefs.js" '// existing preferences'
    & "$repo/install-remote.ps1" -ProfilePath $realProfile -FirefoxDirectory $realFirefox
    Assert-That ($global:LASTEXITCODE -eq 0) 'real downloaded installer failed'
    Assert-That ((Get-FileHash -LiteralPath "$realProfile/chrome/JS/replace-new-tab.uc.js").Hash -eq
        (Get-FileHash -LiteralPath "$repo/JS/replace-new-tab.uc.js").Hash) 'real remote install missed JavaScript'
    Assert-That ((Get-FileHash -LiteralPath "$realProfile/chrome/CSS/firefox-floating-urlbar.uc.css").Hash -eq
        (Get-FileHash -LiteralPath "$repo/CSS/firefox-floating-urlbar.uc.css").Hash) 'real remote install missed stylesheet'
    $state = Join-Path $env:APPDATA 'firefox-floating-urlbar/profile'
    Assert-That ((Get-Content -LiteralPath $state).Trim() -eq $realProfile) 'real remote install missed saved state'
    & "$repo/install-remote.ps1" -Uninstall -ProfilePath $realProfile
    Assert-That ($global:LASTEXITCODE -eq 0) 'real downloaded uninstaller failed'
    Assert-That (-not (Test-Path -LiteralPath "$realProfile/chrome/JS/replace-new-tab.uc.js") -and
        -not (Test-Path -LiteralPath "$realProfile/chrome/CSS/firefox-floating-urlbar.uc.css") -and
        -not (Test-Path -LiteralPath $state)) 'real remote uninstall left payloads or saved state'
    Assert-That ((Get-Content -LiteralPath "$realProfile/chrome/utils/boot.sys.mjs") -eq 'existing external loader') 'real remote uninstall changed external loader'
    $after = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'floating-urlbar-remote-*' | ForEach-Object Name)
    Assert-That (($before -join ',') -eq ($after -join ',')) 'real remote install/uninstall left temporary downloads'
    Write-Host 'PowerShell regressions passed (offline fixtures and temporary installations; no Firefox GUI or UAC-prompt verification).'
} finally {
    $env:APPDATA = $originalAppData
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:FIREFOX_FLOATING_URLBAR_URL = $originalRemoteArchive
    Remove-Variable -Scope Global -Name floatingUrlbarRemoteMode, floatingUrlbarRemoteDownloads, floatingUrlbarRemoteArchive -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
# Expected failing child processes must not become the suite's exit code.
exit 0
