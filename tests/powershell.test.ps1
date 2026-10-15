$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-tests-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temp) | Out-Null
$originalAppData = $env:APPDATA

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-Rejected([scriptblock]$Operation, [string]$Message) {
    $rejected = $false
    try { & $Operation } catch { $rejected = $true }
    Assert-That $rejected $Message
}

try {
    . "$repo/install.ps1"
    $env:APPDATA = Join-Path $temp 'appdata'
    $fixture = Join-Path $temp 'fixture/fx-autoconfig-fixture'
    [IO.Directory]::CreateDirectory("$fixture/program/defaults/pref") | Out-Null
    [IO.Directory]::CreateDirectory("$fixture/profile/chrome/utils") | Out-Null
    Set-Content "$fixture/LICENSE" 'fixture MPL-2.0 license'
    Set-Content "$fixture/program/config.js" '// fixture startup'
    Set-Content "$fixture/program/defaults/pref/config-prefs.js" 'pref("general.config.filename", "config.js");'
    foreach ($file in @('chrome.manifest') + $AutoconfigModules) {
        Set-Content "$fixture/profile/chrome/utils/$file" "fixture $file"
    }
    $fixtureArchive = Join-Path $temp 'fixture.zip'
    Compress-Archive -LiteralPath $fixture -DestinationPath $fixtureArchive
    $AutoconfigPin = @{
        AUTOCONFIG_COMMIT = 'fixture'
        AUTOCONFIG_ZIP_SHA256 = (Get-FileHash -LiteralPath $fixtureArchive).Hash
    }
    $script:downloads = 0
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing) {
        Assert-That ($Uri -eq 'https://codeload.github.com/MrOtherGuy/fx-autoconfig/zip/fixture') 'unexpected download URL'
        $script:downloads++
        Copy-Item -LiteralPath $fixtureArchive -Destination $OutFile
    }
    $ProfilePath = Join-Path $temp 'profile with spaces'
    $FirefoxDirectory = Join-Path $temp 'Mozilla Firefox'
    [IO.Directory]::CreateDirectory($ProfilePath) | Out-Null
    [IO.Directory]::CreateDirectory($FirefoxDirectory) | Out-Null
    Set-Content "$ProfilePath/prefs.js" 'unchanged prefs'
    Set-Content "$FirefoxDirectory/firefox.exe" 'fixture executable'
    Invoke-FloatingUrlbarInstall
    Assert-That (Test-Path "$FirefoxDirectory/config.js") 'missing startup file'
    Assert-That (Test-Path "$FirefoxDirectory/defaults/pref/config-prefs.js") 'missing startup preferences'
    Assert-That (Test-Path "$ProfilePath/chrome/JS/replace-new-tab.uc.js") 'missing JavaScript payload'
    Assert-That (Test-Path "$ProfilePath/chrome/CSS/firefox-floating-urlbar.uc.css") 'missing CSS payload'
    Assert-That ((Get-FileHash "$ProfilePath/chrome/utils/fx-autoconfig.LICENSE").Hash -eq (Get-FileHash "$fixture/LICENSE").Hash) 'upstream license missing or altered'
    Assert-That ((Get-Content "$ProfilePath/chrome/utils/fx-autoconfig.txt" -Raw).Contains('https://github.com/MrOtherGuy/fx-autoconfig/tree/fixture')) 'pinned source notice missing'
    Assert-That ((Get-Content "$ProfilePath/prefs.js") -eq 'unchanged prefs') 'prefs changed'
    Invoke-FloatingUrlbarInstall
    Assert-That ($script:downloads -eq 1) 'downloaded on unchanged reinstall'
    Remove-Item "$ProfilePath/chrome/utils/fs.sys.mjs"
    Invoke-FloatingUrlbarInstall
    Assert-That (Test-Path "$ProfilePath/chrome/utils/fs.sys.mjs") 'failed to repair our missing module'
    Assert-That ($script:downloads -eq 2) 'repair did not fetch source'

    Set-Content "$ProfilePath/chrome/utils/.floating-urlbar-source" 'older'
    Set-Content "$ProfilePath/chrome/utils/boot.sys.mjs" 'local loader edit'
    Invoke-FloatingUrlbarInstall
    $backups = @(Get-ChildItem "$ProfilePath/chrome/utils" -Filter 'boot.sys.mjs.bak-*')
    Assert-That ($backups.Count -eq 1) 'module upgrade did not preserve a backup'
    Assert-That ((Get-Content -LiteralPath $backups[0].FullName) -eq 'local loader edit') 'module backup contents lost'
    Remove-Item "$ProfilePath/chrome/utils/.floating-urlbar-source" -Force
    Set-Content "$ProfilePath/chrome/utils/boot.sys.mjs" 'third-party loader'
    Invoke-FloatingUrlbarInstall
    Assert-That ((Get-Content "$ProfilePath/chrome/utils/boot.sys.mjs") -eq 'third-party loader') 'overwrote existing loader'
    Assert-That ($script:downloads -eq 3) 'existing loader triggered download'

    Set-Content "$ProfilePath/chrome/JS/replace-new-tab.uc.js" 'user script edit'
    $Uninstall = $true
    Invoke-FloatingUrlbarInstall
    Assert-That (-not (Test-Path "$ProfilePath/chrome/JS/replace-new-tab.uc.js")) 'uninstall left payload'
    Assert-That (@(Get-ChildItem "$ProfilePath/chrome/JS" -Filter '*.bak-*').Count -eq 1) 'uninstall lost edited payload'
    Assert-That (Test-Path "$ProfilePath/chrome/utils/boot.sys.mjs") 'uninstall removed shared loader'
    Assert-That (Test-Path "$FirefoxDirectory/config.js") 'uninstall removed shared startup file'
    $Uninstall = $false

    $conflict = Join-Path $temp 'conflicting Firefox'
    [IO.Directory]::CreateDirectory($conflict) | Out-Null
    Set-Content "$conflict/config.js" 'preserve configuration'
    Assert-Rejected { Install-StartupFiles "$fixture/program" $conflict } 'accepted conflicting startup file'
    Assert-That ((Get-Content "$conflict/config.js") -eq 'preserve configuration') 'changed conflicting configuration'
    Assert-That (-not (Test-Path "$conflict/defaults")) 'wrote defaults before conflict check'
    Remove-Item "$conflict/config.js"
    [IO.Directory]::CreateDirectory("$conflict/defaults/pref") | Out-Null
    Set-Content "$conflict/defaults/pref/custom.js" 'pref("general.config.filename", "other.cfg");'
    Assert-Rejected { Install-StartupFiles "$fixture/program" $conflict } 'accepted competing startup preference'
    Assert-That (-not (Test-Path "$conflict/config.js")) 'wrote config despite competing preference'

    $badArchive = Join-Path $temp 'bad.zip'
    Set-Content $badArchive 'corrupt archive'
    Assert-Rejected { Expand-AutoconfigArchive $badArchive "$temp/bad-extraction" } 'accepted corrupt archive'
    Assert-That (-not (Test-Path "$temp/bad-extraction")) 'extracted before checksum verification'

    $outside = Join-Path $temp 'unrelated'
    Set-Content $outside 'unrelated data'
    $linked = Join-Path $temp 'linked'
    New-Item -ItemType SymbolicLink -Path $linked -Target $outside | Out-Null
    Assert-Rejected { Copy-WithBackup "$fixture/program/config.js" $linked } 'accepted symbolic link'
    $hardlink = Join-Path $temp 'hardlink'
    New-Item -ItemType HardLink -Path $hardlink -Target $outside | Out-Null
    Assert-Rejected { Copy-WithBackup "$fixture/program/config.js" $hardlink } 'accepted hard link'
    Assert-That ((Get-Content $outside) -eq 'unrelated data') 'modified linked target'

    $rootFixture = Join-Path $temp 'profile root'
    [IO.Directory]::CreateDirectory("$rootFixture/relative profile") | Out-Null
    Set-Content "$rootFixture/relative profile/prefs.js" 'fixture'
    [IO.File]::WriteAllText("$rootFixture/profiles.ini", "[Profile0]`r`nName=Relative`r`nIsRelative=1`r`nPath=relative profile`r`n[Profile1]`r`nName=Absolute`r`nIsRelative=0`r`nPath=$ProfilePath`r`n")
    $profiles = @(Get-FirefoxProfiles $rootFixture)
    Assert-That ($profiles.Count -eq 2) 'profile discovery missed entries'
    Assert-That ($profiles[0].Path -eq (Join-Path $rootFixture 'relative profile')) 'relative CRLF profile path incorrect'
    Assert-That ($profiles[1].Path -eq $ProfilePath) 'absolute CRLF profile path incorrect'
    Add-Content "$rootFixture/profiles.ini" "[Profile2]`nName=Uninitialized`nDefault=1`nPath=unused`n[InstallTest]`nDefault=relative profile"
    function Read-Host([string]$Prompt) { return '' }
    Assert-That ((Select-FirefoxProfile $rootFixture) -eq (Join-Path $rootFixture 'relative profile')) 'installation default was confused with Default=1'
    Remove-Item Function:Read-Host

    # Stale INI entries must not hide initialized profile folders.
    $fallbackRoot = Join-Path $temp 'fallback profile root'
    $fallbackProfile = Join-Path $fallbackRoot 'usable profile'
    [IO.Directory]::CreateDirectory($fallbackProfile) | Out-Null
    Set-Content "$fallbackProfile/prefs.js" 'fixture'
    Set-Content "$fallbackRoot/profiles.ini" "[Profile0]`nName=Stale`nIsRelative=1`nPath=missing`n[Profile1]`nName=MissingPath"
    $fallbackProfiles = @(Get-FirefoxProfiles $fallbackRoot)
    Assert-That ($fallbackProfiles.Count -eq 1) 'stale INI entries prevented profile folder fallback'
    Assert-That ($fallbackProfiles[0].Path -eq $fallbackProfile) 'fallback returned the wrong profile'
    Assert-That ((Select-FirefoxProfile $fallbackRoot) -eq $fallbackProfile) 'fallback profile could not be selected'
    $nestedProfile = Join-Path (Join-Path $fallbackRoot 'Profiles') 'nested profile'
    [IO.Directory]::CreateDirectory($nestedProfile) | Out-Null
    Set-Content "$nestedProfile/prefs.js" 'fixture'
    $fallbackProfiles = @(Get-FirefoxProfiles $fallbackRoot)
    Assert-That ($fallbackProfiles.Count -eq 2 -and $fallbackProfiles.Path -contains $nestedProfile) 'fallback missed the standard Windows Profiles subfolder'
    $hiddenProfile = Join-Path $fallbackRoot '.hidden profile'
    [IO.Directory]::CreateDirectory($hiddenProfile) | Out-Null
    Set-Content "$hiddenProfile/prefs.js" 'fixture'
    if ($env:OS -eq 'Windows_NT') {
        $hiddenItem = Get-Item -LiteralPath $hiddenProfile -Force
        $hiddenItem.Attributes = $hiddenItem.Attributes -bor [IO.FileAttributes]::Hidden
        Assert-That (($hiddenItem.Attributes -band [IO.FileAttributes]::Hidden) -eq [IO.FileAttributes]::Hidden) 'hidden fixture is not actually hidden'
    }
    $fallbackProfiles = @(Get-FirefoxProfiles $fallbackRoot)
    Assert-That ($fallbackProfiles.Path -contains $hiddenProfile) 'fallback missed hidden profile folder'

    $missingRoot = Join-Path $temp 'missing profile root'
    Assert-That (@(Get-FirefoxProfiles $missingRoot).Count -eq 0) 'missing root did not return zero profiles'
    $profileError = ''
    try { Select-FirefoxProfile $missingRoot } catch { $profileError = $_.Exception.Message }
    Assert-That ($profileError.StartsWith('No initialized Firefox profiles found') -and
        $profileError.Contains('Start Firefox once first.')) 'missing root did not produce the helpful profile error'

    # Test elevation argument quoting and scope without requesting real UAC.
    $script:originalStartupInstall = (Get-Command Install-StartupFiles).ScriptBlock
    $script:elevatedDirectory = Join-Path $temp "Firefox user's install"
    [IO.Directory]::CreateDirectory($script:elevatedDirectory) | Out-Null
    Set-Content "$script:elevatedDirectory/firefox.exe" 'fixture'
    $elevatedProfile = Join-Path $temp 'elevation-profile'
    [IO.Directory]::CreateDirectory($elevatedProfile) | Out-Null
    function Install-StartupFiles { throw [UnauthorizedAccessException]::new('fixture elevation required') }
    function Start-Process([string]$FilePath, [string]$Verb, [switch]$Wait, [switch]$PassThru, [string[]]$ArgumentList) {
        Assert-That ($Verb -eq 'RunAs' -and $Wait -and $PassThru) 'elevation did not wait for its result'
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
        Assert-That ($decoded.Contains("install.ps1' -StartupOnly")) 'elevation invoked the wrong script or operation'
        Assert-That ($decoded.Contains("Firefox user''s install")) 'elevation failed to quote its directory'
        Assert-That (-not $decoded.Contains('-ProfilePath')) 'elevation included user-profile writes'
        & $script:originalStartupInstall "$fixture/program" $script:elevatedDirectory
        return [pscustomobject]@{ ExitCode = 0 }
    }
    Ensure-Autoconfig $elevatedProfile $script:elevatedDirectory
    $cancelledDirectory = Join-Path $temp 'cancelled-Firefox'
    $cancelledProfile = Join-Path $temp 'cancelled-profile'
    [IO.Directory]::CreateDirectory($cancelledDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($cancelledProfile) | Out-Null
    Set-Content "$cancelledDirectory/firefox.exe" 'fixture'
    function Start-Process { throw [ComponentModel.Win32Exception]::new(1223, 'fixture UAC cancelled') }
    $elevationError = ''
    try { Ensure-Autoconfig $cancelledProfile $cancelledDirectory } catch { $elevationError = $_.Exception.Message }
    Assert-That ($elevationError.StartsWith('Firefox startup-file installation failed or elevation was cancelled:') -and
        $elevationError.Contains('fixture UAC cancelled')) 'elevation launch exception lost its context or helpful message'
    Assert-That (-not (Test-Path "$cancelledProfile/chrome")) 'elevation launch exception wrote profile files'
    function Start-Process { return [pscustomobject]@{ ExitCode = 1 } }
    Assert-Rejected { Ensure-Autoconfig $cancelledProfile $cancelledDirectory } 'elevated child failure was accepted'
    Assert-That (-not (Test-Path "$cancelledProfile/chrome")) 'elevated child failure wrote profile files'
    function Start-Process { return [pscustomobject]@{ ExitCode = 0 } }
    Assert-Rejected { Ensure-Autoconfig $cancelledProfile $cancelledDirectory } 'false elevation success was accepted'
    Assert-That (-not (Test-Path "$cancelledProfile/chrome")) 'false elevation success wrote profile files'
    Set-Item Function:Install-StartupFiles -Value $script:originalStartupInstall
    Remove-Item Function:Start-Process
    Assert-That (Test-Path "$elevatedProfile/chrome/utils/boot.sys.mjs") 'profile installation did not resume after elevation'

    # Exercise the actual CLI and the elevated child entry point, still offline.
    $interpreter = (Get-Process -Id $PID).Path
    & $interpreter -NoProfile -NonInteractive -File "$repo/install.ps1" -ProfilePath $ProfilePath
    Assert-That ($LASTEXITCODE -eq 0) 'CLI installation failed for an existing loader'
    $childDirectory = Join-Path $temp 'child-script'
    $childFirefox = Join-Path $temp 'child-Firefox'
    [IO.Directory]::CreateDirectory($childDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($childFirefox) | Out-Null
    Copy-Item -LiteralPath "$repo/install.ps1" -Destination "$childDirectory/install.ps1"
    Set-Content "$childFirefox/firefox.exe" 'fixture'
    Set-Content "$childDirectory/fx-autoconfig.conf" "AUTOCONFIG_COMMIT=fixture`nAUTOCONFIG_ZIP_SHA256=$($AutoconfigPin.AUTOCONFIG_ZIP_SHA256)"
    & $interpreter -NoProfile -NonInteractive -File "$childDirectory/install.ps1" -StartupOnly -FirefoxDirectory $childFirefox -ArchivePath $fixtureArchive
    Assert-That ($LASTEXITCODE -eq 0) 'elevated child entry point failed'
    Assert-That (Test-Path "$childFirefox/defaults/pref/config-prefs.js") 'child did not install startup preferences'

    # Repair current managed loaders without replacing profile modules.
    $repairProfile = Join-Path $temp 'startup-repair-profile'
    $repairFirefox = Join-Path $temp 'startup-repair-Firefox'
    [IO.Directory]::CreateDirectory($repairProfile) | Out-Null
    [IO.Directory]::CreateDirectory($repairFirefox) | Out-Null
    Set-Content "$repairFirefox/firefox.exe" 'fixture executable'
    Set-Content "$repairProfile/prefs.js" 'preserve preferences'
    Ensure-Autoconfig $repairProfile $repairFirefox
    Set-Content "$repairProfile/chrome/utils/boot.sys.mjs" 'preserve local loader edit'
    foreach ($startup in @('config.js', 'defaults/pref/config-prefs.js')) {
        $downloadsBefore = $script:downloads
        Remove-Item -LiteralPath "$repairFirefox/$startup"
        Ensure-Autoconfig $repairProfile $repairFirefox
        Assert-That ((Get-FileHash "$repairFirefox/$startup").Hash -eq (Get-FileHash "$fixture/program/$startup").Hash) "did not restore managed $startup"
        Assert-That ((Get-Content "$repairProfile/chrome/utils/boot.sys.mjs") -eq 'preserve local loader edit') 'startup repair changed profile loader'
        Assert-That ($script:downloads -eq $downloadsBefore + 1) 'startup repair did not fetch source'
    }
    foreach ($notice in @('fx-autoconfig.LICENSE', 'fx-autoconfig.txt')) {
        Remove-Item -LiteralPath "$repairProfile/chrome/utils/$notice"
        Ensure-Autoconfig $repairProfile $repairFirefox
        Assert-That (Test-Path "$repairProfile/chrome/utils/$notice") "did not restore $notice"
        Assert-That ((Get-Content "$repairProfile/chrome/utils/boot.sys.mjs") -eq 'preserve local loader edit') 'notice repair changed profile loader'
    }
    $downloadsBefore = $script:downloads
    Ensure-Autoconfig $repairProfile $repairFirefox
    Assert-That ($script:downloads -eq $downloadsBefore) 'repaired install downloaded again'
    Assert-That ((Get-Content "$repairProfile/prefs.js") -eq 'preserve preferences') 'startup repair changed preferences'

    Remove-Item "$repairFirefox/config.js"
    $originalChecksum = $AutoconfigPin.AUTOCONFIG_ZIP_SHA256
    $AutoconfigPin.AUTOCONFIG_ZIP_SHA256 = 'invalid-checksum'
    Assert-Rejected { Ensure-Autoconfig $repairProfile $repairFirefox } 'startup repair accepted checksum mismatch'
    Assert-That (-not (Test-Path "$repairFirefox/config.js")) 'failed verification wrote startup file'
    $AutoconfigPin.AUTOCONFIG_ZIP_SHA256 = $originalChecksum
    Set-Content "$repairFirefox/defaults/pref/config-prefs.js" 'preserve startup configuration'
    Assert-Rejected { Ensure-Autoconfig $repairProfile $repairFirefox } 'startup repair accepted conflicting configuration'
    Assert-That (-not (Test-Path "$repairFirefox/config.js")) 'startup repair wrote files despite conflict'
    Assert-That ((Get-Content "$repairFirefox/defaults/pref/config-prefs.js") -eq 'preserve startup configuration') 'startup repair changed conflicting configuration'
    Assert-That ((Get-Content "$repairProfile/chrome/utils/boot.sys.mjs") -eq 'preserve local loader edit') 'failed startup repair changed profile loader'

    # Pre-existing loaders warn without taking ownership of their startup files.
    foreach ($startup in @('config.js', 'defaults/pref/config-prefs.js')) {
        $downloadsBefore = $script:downloads
        Remove-Item -LiteralPath "$FirefoxDirectory/$startup"
        $warnings = @(Ensure-Autoconfig $ProfilePath $FirefoxDirectory 3>&1)
        Assert-That (($warnings | Out-String) -match 'standard AutoConfig startup files are missing') 'external loader did not warn about missing startup files'
        Assert-That (-not (Test-Path "$FirefoxDirectory/$startup")) 'changed externally managed startup configuration'
        Assert-That ((Get-Content "$ProfilePath/chrome/utils/boot.sys.mjs") -eq 'third-party loader') 'changed external loader during startup check'
        Assert-That ($script:downloads -eq $downloadsBefore) 'external loader startup check downloaded source'
        Copy-Item -LiteralPath "$fixture/program/$startup" -Destination "$FirefoxDirectory/$startup"
    }

    # Relative inputs follow PowerShell's location even if the process directory differs.
    $psDirectory = Join-Path $temp 'PowerShell location'
    $processDirectory = Join-Path $temp 'process location'
    $relativeProfile = Join-Path $psDirectory 'relative profile'
    $relativeFirefox = Join-Path $psDirectory 'relative Firefox'
    $relativeRoot = Join-Path $psDirectory 'relative root'
    foreach ($directory in @($processDirectory, $relativeProfile, $relativeFirefox, $relativeRoot)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [IO.Directory]::CreateDirectory("$relativeProfile/chrome/utils") | Out-Null
    Set-Content "$relativeProfile/prefs.js" 'preserve relative preferences'
    Set-Content "$relativeProfile/chrome/utils/boot.sys.mjs" 'external loader'
    Set-Content "$relativeProfile/chrome/utils/chrome.manifest" 'external manifest'
    Set-Content "$relativeFirefox/firefox.exe" 'fixture executable'
    [IO.Directory]::CreateDirectory("$relativeFirefox/defaults/pref") | Out-Null
    Copy-Item "$fixture/program/config.js" "$relativeFirefox/config.js"
    Copy-Item "$fixture/program/defaults/pref/config-prefs.js" "$relativeFirefox/defaults/pref/config-prefs.js"
    Set-Content "$relativeRoot/profiles.ini" "[Profile0]`nName=Relative`nIsRelative=1`nPath=../relative profile"
    $originalProcessDirectory = [Environment]::CurrentDirectory
    Push-Location -LiteralPath $psDirectory
    try {
        [Environment]::CurrentDirectory = $processDirectory
        $relativeProfiles = @(Get-FirefoxProfiles 'relative root')
        Assert-That ($relativeProfiles.Count -eq 1 -and $relativeProfiles[0].Path -eq $relativeProfile) 'relative root-derived path used the process directory'
        Assert-That ((Find-FirefoxDirectory 'relative profile' 'relative Firefox') -eq $relativeFirefox) 'relative Firefox directory used the process directory'
        $global:LASTEXITCODE = 0
        & "$repo/install.ps1" -ProfilePath 'relative profile' -FirefoxDirectory 'relative Firefox'
        Assert-That ($global:LASTEXITCODE -eq 0) 'relative profile CLI install failed'
        Assert-That (Test-Path "$relativeProfile/chrome/JS/replace-new-tab.uc.js") 'relative profile CLI install wrote to the wrong location'
        Assert-That ((Get-Content "$relativeProfile/prefs.js") -eq 'preserve relative preferences') 'relative profile CLI install changed preferences'
    } finally {
        [Environment]::CurrentDirectory = $originalProcessDirectory
        Pop-Location
    }

    # Failed first installs retain ownership so a retry repairs the partial loader.
    $interruptedProfile = Join-Path $temp 'interrupted profile'
    $interruptedFirefox = Join-Path $temp 'interrupted Firefox'
    [IO.Directory]::CreateDirectory($interruptedProfile) | Out-Null
    [IO.Directory]::CreateDirectory($interruptedFirefox) | Out-Null
    Set-Content "$interruptedProfile/prefs.js" 'preserve interrupted preferences'
    Set-Content "$interruptedFirefox/firefox.exe" 'fixture executable'
    $originalCopyWithBackup = (Get-Command Copy-WithBackup).ScriptBlock
    function Copy-WithBackup([string]$Source, [string]$Destination) {
        if ((Split-Path $Destination -Leaf) -eq 'fs.sys.mjs') { throw 'fixture module copy failed' }
        & $originalCopyWithBackup $Source $Destination
    }
    try {
        Assert-Rejected { Ensure-Autoconfig $interruptedProfile $interruptedFirefox } 'partial loader copy reported success'
        Assert-That ((Test-Path "$interruptedProfile/chrome/utils/boot.sys.mjs") -and
            (Test-Path "$interruptedProfile/chrome/utils/chrome.manifest") -and
            -not (Test-Path "$interruptedProfile/chrome/utils/fs.sys.mjs")) 'fixture did not reach partial loader state'
        Assert-That ((Get-Content "$interruptedProfile/chrome/utils/.floating-urlbar-source") -eq 'pending') 'partial loader lost its ownership marker'
    } finally { Set-Item Function:Copy-WithBackup -Value $originalCopyWithBackup }
    Ensure-Autoconfig $interruptedProfile $interruptedFirefox
    foreach ($module in $AutoconfigModules) {
        Assert-That ((Get-FileHash "$interruptedProfile/chrome/utils/$module").Hash -eq
            (Get-FileHash "$fixture/profile/chrome/utils/$module").Hash) "retry did not restore $module"
    }
    Assert-That ((Get-Content "$interruptedProfile/chrome/utils/.floating-urlbar-source") -eq 'fixture') 'retry did not finalize loader ownership'

    # Remote launcher: forward options, discard stale status, and clean up on failure.
    $remoteFixture = Join-Path $temp 'remote-fixture/firefox-floating-urlbar-main'
    [IO.Directory]::CreateDirectory($remoteFixture) | Out-Null
    $remoteTrace = Join-Path $temp 'remote-trace.json'
    Set-Content -LiteralPath "$remoteFixture/install.ps1" -Value @'
param([string]$ProfilePath, [switch]$Uninstall)
@{ ProfilePath = $ProfilePath; Uninstall = $Uninstall.IsPresent; Directory = $PSScriptRoot } |
    ConvertTo-Json | Set-Content -LiteralPath $remoteTrace
if ($remoteExit) { exit $remoteExit }
'@
    $remoteArchive = Join-Path $temp 'remote.zip'
    Compress-Archive -LiteralPath $remoteFixture -DestinationPath $remoteArchive
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing) {
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
    Write-Host 'PowerShell regressions passed (offline fixtures and temporary installations; no real Windows/UAC verification).'
} finally {
    $env:APPDATA = $originalAppData
    Remove-Item -LiteralPath $temp -Recurse -Force
}
