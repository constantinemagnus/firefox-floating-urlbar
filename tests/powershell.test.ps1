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

try {
    . "$repo/install.ps1"
    $env:APPDATA = Join-Path $temp 'appdata'
    $env:LOCALAPPDATA = Join-Path $temp 'localappdata'
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
    Assert-That ((Select-FirefoxProfile $rootFixture $ProfilePath) -eq $ProfilePath) 'remembered uninstall profile did not override Firefox default'
    Assert-That ((Select-FirefoxProfile (Join-Path $temp 'absent discovery root') $ProfilePath) -eq $ProfilePath) 'remembered custom profile was lost when discovery failed'
    Remove-Item Function:Read-Host

    # An alternate spelling of the remembered folder must match its row, not add one.
    & {
        function Write-Host([string]$Object) { $script:menuRows++ }
        function Read-Host([string]$Prompt) { return '' }
        foreach ($spelling in @(($ProfilePath + [IO.Path]::DirectorySeparatorChar), (Join-Path $ProfilePath '.'))) {
            $script:menuRows = 0
            $chosen = Select-FirefoxProfile $rootFixture $spelling
            Assert-That ($chosen -eq $ProfilePath) 'alternate remembered spelling did not resolve to the profile'
            Assert-That ($script:menuRows -eq 2) 'alternate remembered spelling added a duplicate menu row'
        }
    }

    # Reverse case: the discovered row carries the alternate spelling.
    & {
        $slashRoot = Join-Path $temp 'trailing slash root'
        [IO.Directory]::CreateDirectory("$slashRoot/slashed") | Out-Null
        Set-Content "$slashRoot/slashed/prefs.js" 'fixture'
        [IO.Directory]::CreateDirectory("$slashRoot/plain") | Out-Null
        Set-Content "$slashRoot/plain/prefs.js" 'fixture'
        [IO.File]::WriteAllText("$slashRoot/profiles.ini", "[Profile0]`r`nName=Slashed`r`nIsRelative=1`r`nPath=slashed/`r`n[Profile1]`r`nName=Plain`r`nIsRelative=1`r`nPath=plain`r`n")
        $slashedPath = Join-Path $slashRoot 'slashed'
        $rows = @(Get-FirefoxProfiles $slashRoot)
        Assert-That ($rows.Count -eq 2) 'trailing-slash INI entry lost a profile'
        Assert-That ($rows[0].Path -eq $slashedPath) 'discovered row kept its trailing separator'
        function Write-Host([string]$Object) { $script:menuRows++ }
        function Read-Host([string]$Prompt) { return '' }
        $script:menuRows = 0
        $chosen = Select-FirefoxProfile $slashRoot $slashedPath
        Assert-That ($chosen -eq $slashedPath) 'plain remembered path did not match the alternate-spelled row'
        Assert-That ($script:menuRows -eq 2) 'alternate-spelled row was duplicated'
    }

    # 8.3 spellings match too, but only where the volume actually mints aliases.
    if ($env:OS -eq 'Windows_NT') {
        & {
            $aliasRoot = Join-Path $temp 'alias probe root'
            $longDir = Join-Path $aliasRoot 'alias probe profile'
            $otherDir = Join-Path $aliasRoot 'other profile'
            foreach ($dir in @($longDir, $otherDir)) {
                [IO.Directory]::CreateDirectory($dir) | Out-Null
                Set-Content "$dir/prefs.js" 'fixture'
            }
            [IO.File]::WriteAllText("$aliasRoot/profiles.ini", "[Profile0]`r`nName=Long`r`nIsRelative=1`r`nPath=alias probe profile`r`n[Profile1]`r`nName=Other`r`nIsRelative=1`r`nPath=other profile`r`n")
            $shortSpelling = ''
            try {
                $shortSpelling = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($longDir).ShortPath
            } catch { $shortSpelling = '' }
            if ($shortSpelling -and $shortSpelling -ne $longDir) {
                function Write-Host([string]$Object) { $script:menuRows++ }
                function Read-Host([string]$Prompt) { return '' }
                $script:menuRows = 0
                $chosen = Select-FirefoxProfile $aliasRoot $shortSpelling
                Assert-That ($chosen -eq $longDir) '8.3 remembered spelling did not match its profile row'
                Assert-That ($script:menuRows -eq 2) '8.3 remembered spelling added a duplicate menu row'
            } else {
                Write-Host 'Skipped 8.3 profile alias check: no short alias available.'
            }
        }
    }

    # Bare uninstall must select a profile even when a saved record exists.
    & {
        $Uninstall = $true
        $ProfilePath = $null
        $Root = $null
        $defaultRoot = Join-Path $env:APPDATA 'Mozilla/Firefox'
        [IO.Directory]::CreateDirectory($defaultRoot) | Out-Null
        $first = Join-Path $defaultRoot 'first'
        $second = Join-Path $defaultRoot 'second'
        foreach ($profile in @($first, $second)) {
            [IO.Directory]::CreateDirectory("$profile/chrome/JS") | Out-Null
            [IO.Directory]::CreateDirectory("$profile/chrome/CSS") | Out-Null
            Set-Content "$profile/prefs.js" 'preserve preferences'
            Copy-Item "$repo/JS/replace-new-tab.uc.js" "$profile/chrome/JS/"
            Copy-Item "$repo/CSS/firefox-floating-urlbar.uc.css" "$profile/chrome/CSS/"
        }
        Set-Content "$defaultRoot/profiles.ini" "[Profile0]`nName=First`nIsRelative=1`nPath=first`n[Profile1]`nName=Second`nIsRelative=1`nPath=second"
        $state = Join-Path $env:APPDATA 'firefox-floating-urlbar/profile'
        Set-Content $state $first
        $script:uninstallPrompts = 0
        function Read-Host([string]$Prompt) { $script:uninstallPrompts++; return '2' }
        Invoke-FloatingUrlbarInstall
        Assert-That ($script:uninstallPrompts -eq 1) 'bare uninstall skipped profile selection'
        Assert-That (Test-Path "$first/chrome/JS/replace-new-tab.uc.js") 'uninstall changed the saved, unselected profile'
        Assert-That (Test-Path "$first/chrome/CSS/firefox-floating-urlbar.uc.css") 'uninstall changed unselected stylesheet'
        Assert-That (-not (Test-Path "$second/chrome/JS/replace-new-tab.uc.js")) 'uninstall ignored selection'
        Assert-That (-not (Test-Path "$second/chrome/CSS/firefox-floating-urlbar.uc.css")) 'uninstall left selected stylesheet'
        Assert-That ((Get-Content "$second/prefs.js") -eq 'preserve preferences') 'uninstall changed preferences'
        Assert-That ((Get-Content $state) -eq $first) 'uninstall forgot another saved profile'
    }

    # Uninstall clears the same saved folder in any spelling, keeps others.
    & {
        $Uninstall = $true
        $Root = $null
        function Read-Host([string]$Prompt) { throw 'unexpected profile prompt' }
        $state = Join-Path $env:APPDATA 'firefox-floating-urlbar/profile'
        $target = Join-Path $temp 'spelling uninstall profile'
        [IO.Directory]::CreateDirectory("$target/chrome/JS") | Out-Null
        [IO.Directory]::CreateDirectory("$target/chrome/CSS") | Out-Null
        Set-Content "$target/prefs.js" 'preserve preferences'
        foreach ($spelling in @(($target + [IO.Path]::DirectorySeparatorChar), (Join-Path $target '.'))) {
            Copy-Item "$repo/JS/replace-new-tab.uc.js" "$target/chrome/JS/"
            Copy-Item "$repo/CSS/firefox-floating-urlbar.uc.css" "$target/chrome/CSS/"
            Set-Content $state $spelling
            $ProfilePath = $target
            Invoke-FloatingUrlbarInstall
            Assert-That (-not (Test-Path "$target/chrome/JS/replace-new-tab.uc.js")) 'alternate saved spelling left payload'
            Assert-That (-not (Test-Path $state)) 'alternate saved spelling did not clear state'
            Assert-That ((Get-Content "$target/prefs.js") -eq 'preserve preferences') 'alternate spelling changed preferences'
        }
        if ($env:OS -eq 'Windows_NT') {
            $shortSpelling = ''
            try { $shortSpelling = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($target).ShortPath } catch { $shortSpelling = '' }
            if ($shortSpelling -and $shortSpelling -ne $target) {
                Copy-Item "$repo/JS/replace-new-tab.uc.js" "$target/chrome/JS/"
                Set-Content $state $shortSpelling
                $ProfilePath = $target
                Invoke-FloatingUrlbarInstall
                Assert-That (-not (Test-Path $state)) '8.3 saved spelling did not clear state'
            }
        }
        Copy-Item "$repo/JS/replace-new-tab.uc.js" "$target/chrome/JS/"
        $other = Join-Path $temp 'other saved profile'
        [IO.Directory]::CreateDirectory($other) | Out-Null
        Set-Content "$other/prefs.js" 'fixture'
        Set-Content $state $other
        $ProfilePath = $target
        Invoke-FloatingUrlbarInstall
        Assert-That (-not (Test-Path "$target/chrome/JS/replace-new-tab.uc.js")) 'uninstall left selected payload'
        Assert-That ((Get-Content $state) -eq $other) 'uninstall cleared a different saved profile'
        Copy-Item "$repo/JS/replace-new-tab.uc.js" "$target/chrome/JS/"
        Set-Content $state 'not a path :::'
        $ProfilePath = $target
        Invoke-FloatingUrlbarInstall
        Assert-That (-not (Test-Path "$target/chrome/JS/replace-new-tab.uc.js")) 'malformed record blocked uninstall'
        Assert-That ((Get-Content $state) -eq 'not a path :::') 'uninstall dropped a malformed record'
        Copy-Item "$repo/JS/replace-new-tab.uc.js" "$target/chrome/JS/"
        [IO.File]::WriteAllText($state, '')
        $ProfilePath = $target
        Invoke-FloatingUrlbarInstall
        Assert-That (-not (Test-Path "$target/chrome/JS/replace-new-tab.uc.js")) 'empty record blocked uninstall'
        Assert-That ((Test-Path -LiteralPath $state -PathType Leaf) -and ("$(Get-Content -LiteralPath $state -Raw)".Trim() -eq '')) 'uninstall dropped an empty record'
    }

    # compatibility.ini LastPlatformDir locates Firefox without an explicit directory.
    & {
        $platformProfile = Join-Path $temp 'platform profile'
        [IO.Directory]::CreateDirectory($platformProfile) | Out-Null
        Set-Content -LiteralPath (Join-Path $platformProfile 'prefs.js') 'fixture'
        Set-Content -LiteralPath (Join-Path $platformProfile 'compatibility.ini') "[Compatibility]`nLastPlatformDir=$FirefoxDirectory"
        Assert-That ((Find-FirefoxDirectory $platformProfile '') -eq $FirefoxDirectory) 'compatibility LastPlatformDir was ignored'
        $explicitFirefox = Join-Path $temp 'explicit Firefox'
        [IO.Directory]::CreateDirectory($explicitFirefox) | Out-Null
        Set-Content -LiteralPath (Join-Path $explicitFirefox 'firefox.exe') 'fixture executable'
        Assert-That ((Find-FirefoxDirectory $platformProfile $explicitFirefox) -eq $explicitFirefox) 'explicit Firefox directory did not win'
    }

    # Literal brackets in INI paths resolve without wildcard expansion.
    & {
        $weirdRoot = Join-Path $temp 'weird names root'
        $bracketed = Join-Path $weirdRoot 'sub [brackets]'
        [IO.Directory]::CreateDirectory($bracketed) | Out-Null
        Set-Content -LiteralPath (Join-Path $bracketed 'prefs.js') 'fixture'
        $weirdPlain = Join-Path $weirdRoot 'plain profile'
        [IO.Directory]::CreateDirectory($weirdPlain) | Out-Null
        Set-Content -LiteralPath (Join-Path $weirdPlain 'prefs.js') 'fixture'
        [IO.File]::WriteAllText((Join-Path $weirdRoot 'profiles.ini'), "[Profile0]`nName=Brackets`nIsRelative=1`nPath=sub [brackets]`n[Profile1]`nName=Plain`nIsRelative=1`nPath=plain profile`n")
        $weirdRows = @(Get-FirefoxProfiles $weirdRoot)
        Assert-That ($weirdRows.Count -eq 2) 'bracketed INI path was not discovered literally'
        function Write-Host([string]$Object) { $script:weirdRows++ }
        function Read-Host([string]$Prompt) { return '' }
        $script:weirdRows = 0
        Assert-That ((Select-FirefoxProfile $weirdRoot (Join-Path $bracketed '.')) -eq $bracketed) 'bracketed remembered spelling missed its row'
        Assert-That ($script:weirdRows -eq 2) 'bracketed spelling added a duplicate row'
    }

    # Unicode folder names resolve through the folder fallback; case on Windows only.
    & {
        $unicodeName = 'prof ' + [char]0xE4 + [char]0xF6 + [char]0xFC
        $unicodeRoot = Join-Path $temp 'unicode root'
        $unicodeProfile = Join-Path $unicodeRoot $unicodeName
        $unicodeOther = Join-Path $unicodeRoot 'other profile'
        foreach ($dir in @($unicodeProfile, $unicodeOther)) {
            [IO.Directory]::CreateDirectory($dir) | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'prefs.js') 'fixture'
        }
        Assert-That (@(Get-FirefoxProfiles $unicodeRoot).Count -eq 2) 'Unicode folder fallback missed a profile'
        function Write-Host([string]$Object) { $script:unicodeRows++ }
        function Read-Host([string]$Prompt) { return '' }
        $script:unicodeRows = 0
        Assert-That ((Select-FirefoxProfile $unicodeRoot $unicodeProfile) -eq $unicodeProfile) 'Unicode remembered spelling missed its row'
        Assert-That ($script:unicodeRows -eq 2) 'Unicode spelling added a duplicate row'
        if ($env:OS -eq 'Windows_NT') {
            $script:unicodeRows = 0
            Assert-That ((Select-FirefoxProfile $unicodeRoot $unicodeProfile.ToUpperInvariant()) -eq $unicodeProfile) 'case spelling missed its row'
            Assert-That ($script:unicodeRows -eq 2) 'case spelling added a duplicate row'
        }
    }

    # A junctioned chrome directory is refused before anything is written.
    if ($env:OS -eq 'Windows_NT') {
        & {
            $Uninstall = $false
            function Read-Host([string]$Prompt) { throw 'unexpected profile prompt' }
            $jProfile = Join-Path $temp 'junction profile'
            [IO.Directory]::CreateDirectory($jProfile) | Out-Null
            Set-Content -LiteralPath (Join-Path $jProfile 'prefs.js') 'preserve preferences'
            $jOutside = Join-Path $temp 'junction outside'
            [IO.Directory]::CreateDirectory($jOutside) | Out-Null
            Set-Content -LiteralPath (Join-Path $jOutside 'marker.txt') 'must survive'
            New-Item -ItemType Junction -Path (Join-Path $jProfile 'chrome') -Target $jOutside | Out-Null
            Assert-Rejected { Assert-Destination (Join-Path $jProfile 'chrome') -Directory } 'junctioned directory was accepted'
            $ProfilePath = $jProfile
            Assert-Rejected { Invoke-FloatingUrlbarInstall } 'install into a junctioned chrome directory was accepted'
            Assert-That ((Get-Content -LiteralPath (Join-Path $jOutside 'marker.txt')) -eq 'must survive') 'junction target was modified'
            Assert-That (-not (Test-Path (Join-Path (Join-Path $jOutside 'JS') 'replace-new-tab.uc.js'))) 'payload was written through the junction'
        }
    }

    # Empty or missing profiles.ini still falls back to profile folders.
    & {
        $iniRoot = Join-Path $temp 'empty ini root'
        $iniProfile = Join-Path $iniRoot 'lonely profile'
        [IO.Directory]::CreateDirectory($iniProfile) | Out-Null
        Set-Content -LiteralPath (Join-Path $iniProfile 'prefs.js') 'fixture'
        [IO.File]::WriteAllText((Join-Path $iniRoot 'profiles.ini'), '')
        $iniFound = @(Get-FirefoxProfiles $iniRoot)
        Assert-That ($iniFound.Count -eq 1 -and $iniFound[0].Path -eq $iniProfile) 'empty profiles.ini hid the folder fallback'
        Remove-Item -LiteralPath (Join-Path $iniRoot 'profiles.ini')
        $iniFound = @(Get-FirefoxProfiles $iniRoot)
        Assert-That ($iniFound.Count -eq 1 -and $iniFound[0].Path -eq $iniProfile) 'missing profiles.ini hid the folder fallback'
    }

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

    # Second-payload failures must preserve both files and remembered state.
    foreach ($state in @('existing', 'fresh')) {
        foreach ($phase in @('stage', 'backup', 'replace')) {
            if ($state -eq 'fresh' -and $phase -eq 'backup') { continue }
            & {
                $Uninstall = $false
                $ProfilePath = Join-Path $temp "payload-$state-$phase"
                foreach ($dir in @('JS', 'CSS', 'utils')) {
                    [IO.Directory]::CreateDirectory("$ProfilePath/chrome/$dir") | Out-Null
                }
                Set-Content "$ProfilePath/prefs.js" 'preserve preferences'
                Set-Content "$ProfilePath/chrome/utils/boot.sys.mjs" 'external loader'
                Set-Content "$ProfilePath/chrome/utils/chrome.manifest" 'external manifest'
                $js = Join-Path $ProfilePath 'chrome/JS/replace-new-tab.uc.js'
                $css = Join-Path $ProfilePath 'chrome/CSS/firefox-floating-urlbar.uc.css'
                if ($state -eq 'existing') {
                    Set-Content -LiteralPath $js -Value 'original JS'
                    Set-Content -LiteralPath $css -Value 'original CSS'
                }
                $remembered = Join-Path $env:APPDATA 'firefox-floating-urlbar/profile'
                $stateBefore = if (Test-Path -LiteralPath $remembered) { Get-Content -LiteralPath $remembered -Raw } else { $null }
                function Copy-Item {
                    [CmdletBinding()]
                    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                    if (($phase -eq 'stage' -and $LiteralPath -eq (Join-Path $repo 'CSS/firefox-floating-urlbar.uc.css')) -or
                        ($phase -eq 'backup' -and $Destination -like '*firefox-floating-urlbar.uc.css.bak-*')) {
                        throw 'fixture second-payload copy failure'
                    }
                    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
                }
                function Move-Item {
                    [CmdletBinding()]
                    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                    if ($phase -eq 'replace' -and $LiteralPath -like '*.floating-urlbar-install.*' -and
                        (Split-Path $LiteralPath -Leaf) -eq 'firefox-floating-urlbar.uc.css') {
                        throw 'fixture second-payload replacement failure'
                    }
                    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
                }
                Assert-Rejected { Invoke-FloatingUrlbarInstall } "accepted $state payload $phase failure"
                if ($state -eq 'existing') {
                    Assert-That ((Get-Content -LiteralPath $js) -eq 'original JS') "$phase did not restore JavaScript"
                    Assert-That ((Get-Content -LiteralPath $css) -eq 'original CSS') "$phase did not preserve CSS"
                } else {
                    Assert-That (-not (Test-Path -LiteralPath $js) -and -not (Test-Path -LiteralPath $css)) "$phase left a partial fresh installation"
                }
                $stateAfter = if (Test-Path -LiteralPath $remembered) { Get-Content -LiteralPath $remembered -Raw } else { $null }
                Assert-That ($stateAfter -eq $stateBefore) "$phase changed remembered state"
                Assert-That (@(Get-ChildItem -LiteralPath "$ProfilePath/chrome" -Directory -Force |
                    Where-Object Name -Like '.floating-urlbar-install.*').Count -eq 0) "$phase leaked staged files"
            }
        }
    }

    # A retry heals an interrupted receipt copy before startup files exist.
    foreach ($receiptState in @('empty', 'truncated')) {
        $recoveryFirefox = Join-Path $temp "receipt-$receiptState/Firefox"
        [IO.Directory]::CreateDirectory($recoveryFirefox) | Out-Null
        $receipt = Join-Path $recoveryFirefox '.floating-urlbar-autoconfig'
        $contents = if ($receiptState -eq 'empty') { '' } else { 'partial ownership record' }
        [IO.File]::WriteAllText($receipt, $contents)
        Install-StartupFiles "$fixture/program" $recoveryFirefox
        Assert-AutoconfigReceipt $receipt $recoveryFirefox @('config.js', 'defaults/pref/config-prefs.js')
        Remove-SharedAutoconfig $recoveryFirefox
        Assert-That (-not (Test-Path -LiteralPath "$recoveryFirefox/config.js") -and
            -not (Test-Path -LiteralPath $receipt)) "$receiptState shared receipt was not recovered"
    }

    foreach ($receiptState in @('empty', 'truncated', 'invalid', 'duplicate', 'edited', 'edited-module', 'lowercase')) {
        $recoveryProfile = Join-Path $temp "profile-receipt-$receiptState/profile"
        $recoveryFirefox = Join-Path $temp "profile-receipt-$receiptState/Firefox"
        [IO.Directory]::CreateDirectory($recoveryFirefox) | Out-Null
        Set-Content "$recoveryFirefox/firefox.exe" 'fixture'
        Ensure-Autoconfig $recoveryProfile $recoveryFirefox
        $receipt = "$recoveryProfile/chrome/utils/.floating-urlbar-files"
        $lines = @(Get-Content -LiteralPath $receipt)
        $editedFile = if ($receiptState -eq 'edited-module') { 'fs.sys.mjs' } else { 'boot.sys.mjs' }
        switch ($receiptState) {
            'empty' { [IO.File]::WriteAllText($receipt, '') }
            'truncated' { Set-Content -LiteralPath $receipt -Value $lines[0..5] }
            'invalid' { Set-Content -LiteralPath $receipt -Value 'invalid receipt' }
            'duplicate' { Add-Content -LiteralPath $receipt -Value $lines[0] }
            { $_ -in @('edited', 'edited-module') } {
                Set-Content -LiteralPath $receipt -Value $lines[0..5]
                Set-Content "$recoveryProfile/chrome/utils/$editedFile" 'preserve local edit'
            }
            'lowercase' { Set-Content -LiteralPath $receipt -Value ($lines | ForEach-Object { $_.Substring(0, 64).ToLowerInvariant() + $_.Substring(64) }) }
        }
        Ensure-Autoconfig $recoveryProfile $recoveryFirefox
        Assert-That (@(Get-Content -LiteralPath $receipt).Count -eq 8) "$receiptState profile receipt was not repaired"
        if ($receiptState -in @('edited', 'edited-module')) {
            Assert-Rejected { Remove-ManagedAutoconfig $recoveryProfile $recoveryFirefox $false } 'receipt repair claimed local edit'
            Assert-Rejected { Remove-ManagedAutoconfig $recoveryProfile $recoveryFirefox $true } 'receipt repair bypassed shared cleanup safeguards'
            Assert-That ((Get-Content "$recoveryProfile/chrome/utils/$editedFile") -eq 'preserve local edit') 'receipt repair lost local edit'
            Assert-That (Test-Path "$recoveryFirefox/config.js") 'receipt repair allowed partial shared cleanup'
        } else {
            Remove-ManagedAutoconfig $recoveryProfile $recoveryFirefox $false
        }
    }

    $cycleProfile = Join-Path $temp 'receipt-backup-cycle/profile'
    $cycleFirefox = Join-Path $temp 'receipt-backup-cycle/Firefox'
    [IO.Directory]::CreateDirectory($cycleFirefox) | Out-Null
    Set-Content "$cycleFirefox/firefox.exe" 'fixture'
    Ensure-Autoconfig $cycleProfile $cycleFirefox
    Set-Content "$cycleProfile/chrome/utils/fx-autoconfig.txt" 'preserve edited notice'
    Set-Content "$cycleProfile/chrome/utils/.floating-urlbar-files" 'damaged receipt'
    Ensure-Autoconfig $cycleProfile $cycleFirefox
    $noticeBackups = @(Get-ChildItem "$cycleProfile/chrome/utils" -Filter 'fx-autoconfig.txt.bak-*')
    Assert-That ($noticeBackups.Count -eq 1 -and (Get-Content -LiteralPath $noticeBackups[0].FullName) -eq 'preserve edited notice') 'receipt repair lost edited notice'
    Remove-ManagedAutoconfig $cycleProfile $cycleFirefox $false
    Ensure-Autoconfig $cycleProfile $cycleFirefox
    Assert-That ((Get-Content -LiteralPath $noticeBackups[0].FullName) -eq 'preserve edited notice') 'reinstall changed notice backup'

    $emptyProfile = Join-Path $temp 'cleanup-empty/profile'
    $emptyFirefox = Join-Path $temp 'cleanup-empty/Firefox'
    [IO.Directory]::CreateDirectory($emptyFirefox) | Out-Null
    Set-Content "$emptyFirefox/firefox.exe" 'fixture'
    [IO.Directory]::CreateDirectory("$emptyProfile/chrome") | Out-Null
    Set-Content "$emptyProfile/chrome/other.css" 'unrelated native style'
    Remove-ManagedAutoconfig $emptyProfile $emptyFirefox $false
    $originalSharedRemoval = (Get-Command Remove-SharedAutoconfig).ScriptBlock
    function Remove-SharedAutoconfig { throw 'No-op cleanup called the removal routine' }
    try { Remove-ManagedAutoconfig $emptyProfile $emptyFirefox $true }
    finally { Set-Item Function:Remove-SharedAutoconfig -Value $originalSharedRemoval }
    Remove-Item "$emptyProfile/chrome/other.css"
    Ensure-Autoconfig $emptyProfile $emptyFirefox
    [IO.Directory]::CreateDirectory("$emptyProfile/chrome/assets.css") | Out-Null
    [IO.Directory]::CreateDirectory("$emptyProfile/chrome/utils/module.bak-old") | Out-Null
    Remove-ManagedAutoconfig $emptyProfile $emptyFirefox $true
    Remove-ManagedAutoconfig $emptyProfile $emptyFirefox $true
    Remove-SharedAutoconfig $emptyFirefox
    Assert-That ((Test-Path "$emptyProfile/chrome/assets.css") -and (Test-Path "$emptyProfile/chrome/utils/module.bak-old")) 'cleanup removed untouched directories'

    # Even no-op cleanup validates shared paths without invoking removal.
    $linkedFirefox = Join-Path $temp 'cleanup-empty-linked/Firefox'
    $linkedDefaults = Join-Path $temp 'cleanup-empty-linked/target'
    [IO.Directory]::CreateDirectory($linkedFirefox) | Out-Null
    [IO.Directory]::CreateDirectory($linkedDefaults) | Out-Null
    Set-Content "$linkedFirefox/firefox.exe" 'fixture'
    New-Item -ItemType SymbolicLink -Path "$linkedFirefox/defaults" -Target $linkedDefaults | Out-Null
    Assert-Rejected { Remove-ManagedAutoconfig $emptyProfile $linkedFirefox $true } 'no-op cleanup accepted linked shared paths'

    foreach ($receiptState in @('missing', 'invalid', 'incomplete')) {
        $recoveryFirefox = Join-Path $temp "shared-recovery-$receiptState/Firefox"
        [IO.Directory]::CreateDirectory($recoveryFirefox) | Out-Null
        Install-StartupFiles "$fixture/program" $recoveryFirefox
        $receipt = "$recoveryFirefox/.floating-urlbar-autoconfig"
        switch ($receiptState) {
            'missing' { Remove-Item -LiteralPath $receipt -Force }
            'invalid' { Set-Content -LiteralPath $receipt -Value 'damaged receipt' }
            'incomplete' { Set-Content -LiteralPath $receipt -Value @(Get-Content -LiteralPath $receipt)[0] }
        }
        $message = ''
        try { Remove-SharedAutoconfig $recoveryFirefox } catch { $message = $_.Exception.Message }
        Assert-That ($message.Contains('Shared startup ownership cannot be restored by reinstalling')) 'shared recovery message suggested reinstall'
        Assert-That ((Test-Path "$recoveryFirefox/config.js") -and (Test-Path "$recoveryFirefox/defaults/pref/config-prefs.js")) 'shared receipt failure removed startup files'
    }

    & {
        # Download failure cannot rewrite a damaged receipt or a local module edit.
        Set-Content "$cycleProfile/chrome/utils/.floating-urlbar-files" 'damaged receipt'
        Set-Content "$cycleProfile/chrome/utils/fs.sys.mjs" 'preserve offline edit'
        function Invoke-WebRequest { throw 'fixture offline receipt repair' }
        Assert-Rejected { Ensure-Autoconfig $cycleProfile $cycleFirefox } 'offline receipt repair reported success'
        Assert-That ((Get-Content "$cycleProfile/chrome/utils/.floating-urlbar-files") -eq 'damaged receipt' -and
            (Get-Content "$cycleProfile/chrome/utils/fs.sys.mjs") -eq 'preserve offline edit') 'offline receipt repair changed local files'
    }

    foreach ($answer in @('', 'n', 'no', 'invalid', 'y', 'YES')) {
        function Read-Host { return $answer }
        Assert-That ((Read-CleanupConfirmation 'fixture') -eq ($answer -in @('y', 'yes'))) "incorrect cleanup response: $answer"
    }
    function Read-Host { throw 'fixture stdin failure' }
    Assert-That (-not (Read-CleanupConfirmation 'fixture')) 'stdin failure allowed cleanup'
    Remove-Item Function:Read-Host

    # Optional loader refusal must leave the completed payload uninstall recorded.
    & {
        $ProfilePath = Join-Path $temp 'cleanup-housekeeping/profile'
        $FirefoxDirectory = Join-Path $temp 'cleanup-housekeeping/Firefox'
        [IO.Directory]::CreateDirectory($ProfilePath) | Out-Null
        [IO.Directory]::CreateDirectory($FirefoxDirectory) | Out-Null
        Set-Content -LiteralPath "$ProfilePath/prefs.js" 'preserve preferences'
        Set-Content -LiteralPath "$FirefoxDirectory/firefox.exe" 'fixture'
        $StartupOnly = $false
        $Uninstall = $false
        $RemoveAutoconfig = $false
        $RemoveSharedAutoconfig = $false
        Invoke-FloatingUrlbarInstall
        Remove-Item -LiteralPath "$ProfilePath/chrome/utils/.floating-urlbar-source" -Force
        $Uninstall = $true
        $RemoveAutoconfig = $true
        Assert-Rejected { Invoke-FloatingUrlbarInstall } 'unowned loader cleanup succeeded'
        Assert-That (-not (Test-Path -LiteralPath "$ProfilePath/chrome/JS/replace-new-tab.uc.js") -and
            -not (Test-Path -LiteralPath "$ProfilePath/chrome/CSS/firefox-floating-urlbar.uc.css")) 'cleanup refusal left payloads'
        Assert-That (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'firefox-floating-urlbar/profile'))) 'cleanup refusal skipped saved-state cleanup'
        Assert-That ((Test-Path -LiteralPath "$ProfilePath/chrome/utils/boot.sys.mjs") -and
            (Test-Path -LiteralPath "$FirefoxDirectory/config.js")) 'cleanup refusal removed unowned loader'
    }

    # Cleanup requires ownership, unchanged files, and no dependent customization.
    foreach ($cleanup in @('profile', 'shared', 'edited', 'other-script', 'other-style', 'linked-native', 'other-utils', 'external', 'shared-edited', 'shared-unowned', 'malformed', 'linked', 'hardlinked')) {
        $cleanupProfile = Join-Path $temp "cleanup-$cleanup/profile"
        $cleanupFirefox = Join-Path $temp "cleanup-$cleanup/Firefox"
        [IO.Directory]::CreateDirectory($cleanupProfile) | Out-Null
        [IO.Directory]::CreateDirectory($cleanupFirefox) | Out-Null
        Set-Content "$cleanupProfile/prefs.js" 'preserve preferences'
        Set-Content "$cleanupFirefox/firefox.exe" 'fixture'
        if ($cleanup -eq 'shared-unowned') {
            [IO.Directory]::CreateDirectory("$cleanupFirefox/defaults/pref") | Out-Null
            Copy-Item "$fixture/program/config.js" "$cleanupFirefox/config.js"
            Copy-Item "$fixture/program/defaults/pref/config-prefs.js" "$cleanupFirefox/defaults/pref/config-prefs.js"
        }
        Ensure-Autoconfig $cleanupProfile $cleanupFirefox
        switch ($cleanup) {
            'profile' {
                Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $false
                Assert-That (-not (Test-Path "$cleanupProfile/chrome/utils") -and (Test-Path "$cleanupFirefox/config.js")) 'profile cleanup changed shared files or left loader'
            }
            'shared' {
                Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $true
                Assert-That (-not (Test-Path "$cleanupProfile/chrome/utils") -and -not (Test-Path "$cleanupFirefox/config.js") -and
                    -not (Test-Path "$cleanupFirefox/defaults/pref/config-prefs.js") -and -not (Test-Path "$cleanupFirefox/.floating-urlbar-autoconfig")) 'full cleanup left owned files'
            }
            default {
                switch ($cleanup) {
                    'edited' { Set-Content "$cleanupProfile/chrome/utils/boot.sys.mjs" 'local edit' }
                    'other-script' { Set-Content "$cleanupProfile/chrome/JS/other.uc.js" 'other script' }
                    'other-style' { Set-Content "$cleanupProfile/chrome/CSS/userChrome.css" 'nested style' }
                    'linked-native' { New-Item -ItemType SymbolicLink -Path "$cleanupProfile/chrome/userChrome.css" -Target "$fixture/program/config.js" | Out-Null }
                    'other-utils' { Set-Content "$cleanupProfile/chrome/utils/other.sys.mjs" 'other module' }
                    'external' { Remove-Item "$cleanupProfile/chrome/utils/.floating-urlbar-source" -Force }
                    'shared-edited' { Set-Content "$cleanupFirefox/config.js" 'local startup edit' }
                    'malformed' { Set-Content "$cleanupProfile/chrome/utils/.floating-urlbar-files" "$('0' * 64) ../prefs.js" }
                    'linked' {
                        Remove-Item "$cleanupProfile/chrome/utils/boot.sys.mjs"
                        New-Item -ItemType SymbolicLink -Path "$cleanupProfile/chrome/utils/boot.sys.mjs" -Target "$fixture/profile/chrome/utils/boot.sys.mjs" | Out-Null
                    }
                    'hardlinked' {
                        Remove-Item "$cleanupProfile/chrome/utils/boot.sys.mjs"
                        New-Item -ItemType HardLink -Path "$cleanupProfile/chrome/utils/boot.sys.mjs" -Target "$fixture/profile/chrome/utils/boot.sys.mjs" | Out-Null
                    }
                }
                Assert-Rejected { Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $true } "unsafe $cleanup cleanup succeeded"
                Assert-That ((Test-Path "$cleanupProfile/chrome/utils/chrome.manifest") -and (Test-Path "$cleanupFirefox/config.js")) "$cleanup cleanup partially removed loader"
            }
        }
        Assert-That ((Get-Content "$cleanupProfile/prefs.js") -eq 'preserve preferences') "$cleanup cleanup changed preferences"
    }

    foreach ($cleanup in @('delayed', 'delayed-backup', 'delayed-edited', 'delayed-unowned', 'missing-chrome', 'native-styles')) {
        $cleanupProfile = Join-Path $temp "cleanup-$cleanup/profile [2024]"
        $cleanupFirefox = Join-Path $temp "cleanup-$cleanup/Firefox [2024]"
        [IO.Directory]::CreateDirectory($cleanupProfile) | Out-Null
        [IO.Directory]::CreateDirectory($cleanupFirefox) | Out-Null
        Set-Content -LiteralPath "$cleanupFirefox/firefox.exe" 'fixture'
        Ensure-Autoconfig $cleanupProfile $cleanupFirefox
        if ($cleanup -eq 'missing-chrome') {
            Remove-Item -LiteralPath "$cleanupProfile/chrome" -Recurse -Force
        } elseif ($cleanup -like 'delayed*') {
            if ($cleanup -eq 'delayed-backup') {
                Set-Content -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs.bak-old" 'preserve backup'
            }
            Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $false
            Assert-That (-not (Test-Path -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs") -and (Test-Path -LiteralPath "$cleanupFirefox/config.js")) 'first cleanup did not leave shared files'
            if ($cleanup -eq 'delayed-edited') {
                Set-Content -LiteralPath "$cleanupFirefox/config.js" 'local startup edit'
            } elseif ($cleanup -eq 'delayed-unowned') {
                [IO.Directory]::CreateDirectory("$cleanupProfile/chrome/utils") | Out-Null
                Set-Content -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs" 'external loader'
            }
        } else {
            Set-Content -LiteralPath "$cleanupProfile/chrome/userChrome.css" 'native chrome style'
            Set-Content -LiteralPath "$cleanupProfile/chrome/userContent.css" 'native content style'
        }
        if ($cleanup -in @('delayed-edited', 'delayed-unowned')) {
            Assert-Rejected { Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $true } "unsafe $cleanup succeeded"
            Assert-That ((Test-Path -LiteralPath "$cleanupFirefox/config.js") -and
                (Test-Path -LiteralPath "$cleanupFirefox/defaults/pref/config-prefs.js") -and
                (Test-Path -LiteralPath "$cleanupFirefox/.floating-urlbar-autoconfig")) "$cleanup removed shared files"
            if ($cleanup -eq 'delayed-unowned') {
                Assert-That ((Get-Content -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs") -eq 'external loader') 'delayed cleanup removed unowned loader'
            }
            continue
        }
        Remove-ManagedAutoconfig $cleanupProfile $cleanupFirefox $true
        Assert-That (-not (Test-Path -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs") -and
            -not (Test-Path -LiteralPath "$cleanupFirefox/config.js") -and
            -not (Test-Path -LiteralPath "$cleanupFirefox/.floating-urlbar-autoconfig")) "$cleanup left owned files"
        if ($cleanup -eq 'delayed-backup') {
            Assert-That ((Get-Content -LiteralPath "$cleanupProfile/chrome/utils/boot.sys.mjs.bak-old") -eq 'preserve backup') 'delayed cleanup lost backup'
        } elseif ($cleanup -eq 'native-styles') {
            Assert-That ((Get-Content -LiteralPath "$cleanupProfile/chrome/userChrome.css") -eq 'native chrome style' -and
                (Get-Content -LiteralPath "$cleanupProfile/chrome/userContent.css") -eq 'native content style') 'cleanup changed native styles'
        }
    }

    $unownedFirefox = Join-Path $temp 'preexisting Firefox [2024]'
    [IO.Directory]::CreateDirectory("$unownedFirefox/defaults/pref") | Out-Null
    Copy-Item -LiteralPath "$fixture/program/config.js" -Destination "$unownedFirefox/config.js"
    Copy-Item -LiteralPath "$fixture/program/defaults/pref/config-prefs.js" -Destination "$unownedFirefox/defaults/pref/config-prefs.js"
    Install-StartupFiles "$fixture/program" $unownedFirefox
    Assert-That (-not (Test-Path -LiteralPath "$unownedFirefox/.floating-urlbar-autoconfig")) 'claimed preexisting startup files in bracketed path'

    # Legacy receipts are reconstructed from verified source, never from local edits.
    foreach ($legacy in @('unchanged', 'edited')) {
        $legacyProfile = Join-Path $temp "legacy-$legacy/profile"
        $legacyFirefox = Join-Path $temp "legacy-$legacy/Firefox"
        [IO.Directory]::CreateDirectory($legacyProfile) | Out-Null
        [IO.Directory]::CreateDirectory($legacyFirefox) | Out-Null
        Set-Content "$legacyFirefox/firefox.exe" 'fixture'
        Ensure-Autoconfig $legacyProfile $legacyFirefox
        Remove-Item "$legacyProfile/chrome/utils/.floating-urlbar-files", "$legacyFirefox/.floating-urlbar-autoconfig" -Force
        if ($legacy -eq 'edited') { Set-Content "$legacyProfile/chrome/utils/boot.sys.mjs" 'legacy local edit' }
        Ensure-Autoconfig $legacyProfile $legacyFirefox
        Assert-That ((Test-Path "$legacyProfile/chrome/utils/.floating-urlbar-files") -and
            -not (Test-Path "$legacyFirefox/.floating-urlbar-autoconfig")) 'legacy migration claimed shared files or missed profile receipt'
        if ($legacy -eq 'unchanged') {
            Remove-ManagedAutoconfig $legacyProfile $legacyFirefox $false
            Assert-That (-not (Test-Path "$legacyProfile/chrome/utils") -and (Test-Path "$legacyFirefox/config.js")) 'legacy profile cleanup failed'
        } else {
            Assert-Rejected { Remove-ManagedAutoconfig $legacyProfile $legacyFirefox $false } 'legacy migration claimed local edits'
            Assert-That ((Get-Content "$legacyProfile/chrome/utils/boot.sys.mjs") -eq 'legacy local edit') 'legacy local edit lost'
        }
    }

    # Shared cleanup elevates only the startup-file operation, and checks the result.
    $script:originalSharedRemoval = (Get-Command Remove-SharedAutoconfig).ScriptBlock
    foreach ($outcome in @('success', 'cancelled', 'false-success')) {
        $script:removalProfile = Join-Path $temp "cleanup-elevated-$outcome/profile"
        $script:removalFirefox = Join-Path $temp "cleanup-elevated-$outcome/Firefox user's install"
        [IO.Directory]::CreateDirectory($script:removalProfile) | Out-Null
        [IO.Directory]::CreateDirectory($script:removalFirefox) | Out-Null
        Set-Content "$script:removalFirefox/firefox.exe" 'fixture'
        Ensure-Autoconfig $script:removalProfile $script:removalFirefox
        function Remove-SharedAutoconfig { throw [UnauthorizedAccessException]::new('fixture elevation required') }
        $script:removalOutcome = $outcome
        function Start-Process([string]$FilePath, [string]$Verb, [switch]$Wait, [switch]$PassThru, [string[]]$ArgumentList) {
            Assert-That ($Verb -eq 'RunAs' -and $Wait -and $PassThru) 'cleanup elevation did not wait for completion'
            $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            Assert-That ($decoded.Contains('-StartupOnly -RemoveSharedAutoconfig') -and -not $decoded.Contains('-ProfilePath') -and
                $decoded.Contains("Firefox user''s install")) 'cleanup elevated the wrong operation or failed to quote its directory'
            if ($script:removalOutcome -eq 'cancelled') { throw [ComponentModel.Win32Exception]::new(1223, 'fixture UAC cancelled') }
            if ($script:removalOutcome -eq 'success') { & $script:originalSharedRemoval $script:removalFirefox }
            return [pscustomobject]@{ ExitCode = 0 }
        }
        try {
            if ($outcome -eq 'success') {
                Remove-ManagedAutoconfig $script:removalProfile $script:removalFirefox $true
                Assert-That (-not (Test-Path "$script:removalProfile/chrome/utils")) 'cleanup did not resume after elevation'
            } else {
                $message = ''
                try { Remove-ManagedAutoconfig $script:removalProfile $script:removalFirefox $true }
                catch { $message = $_.Exception.Message }
                Assert-That ($message -ne '') "accepted $outcome cleanup elevation"
                if ($outcome -eq 'cancelled') {
                    Assert-That ($message.StartsWith('Shared fx-autoconfig removal failed or elevation was cancelled:') -and
                        $message.Contains('fixture UAC cancelled')) 'cleanup cancellation lacked actionable context'
                }
                Assert-That ((Test-Path "$script:removalProfile/chrome/utils/boot.sys.mjs") -and
                    (Test-Path "$script:removalFirefox/config.js")) "$outcome cleanup elevation removed loader files"
            }
        } finally {
            Set-Item Function:Remove-SharedAutoconfig -Value $script:originalSharedRemoval
            Remove-Item Function:Start-Process
        }
    }

    # Exercise the elevated shared-cleanup entry point without real UAC.
    $cleanupChild = Join-Path $temp 'cleanup-child-Firefox'
    [IO.Directory]::CreateDirectory($cleanupChild) | Out-Null
    Set-Content "$cleanupChild/firefox.exe" 'fixture'
    Install-StartupFiles "$fixture/program" $cleanupChild
    & $interpreter -NoProfile -NonInteractive -File "$childDirectory/install.ps1" -StartupOnly -RemoveSharedAutoconfig -FirefoxDirectory $cleanupChild
    Assert-That ($LASTEXITCODE -eq 0 -and -not (Test-Path "$cleanupChild/config.js")) 'shared-cleanup child entry point failed'

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
    $global:floatingUrlbarRemoteMode = 'string'
    function Invoke-WebRequest([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [hashtable]$Headers) {
        if ($Uri -like 'https://api.github.com/*') {
            Assert-That ($Headers.Accept -eq 'application/vnd.github.sha') 'remote launcher did not request an immutable revision'
            if ($global:floatingUrlbarRemoteMode -eq 'api-error') { throw 'fixture API failure' }
            $revision = if ($global:floatingUrlbarRemoteMode -eq 'invalid-revision') { '{"message":"rate limited"}' } else { 'a' * 40 }
            if ($global:floatingUrlbarRemoteMode -eq 'bytes') { return @{ Content = [Text.Encoding]::UTF8.GetBytes($revision) } }
            return @{ Content = $revision }
        }
        $prefix = "https://raw.githubusercontent.com/constantinemagnus/firefox-floating-urlbar/$('a' * 40)/"
        Assert-That ($Uri.StartsWith($prefix)) 'remote files did not use the resolved commit'
        $file = $Uri.Substring($prefix.Length)
        $global:floatingUrlbarRemoteDownloads += $file
        if ($file -eq 'fx-autoconfig.conf' -and $global:floatingUrlbarRemoteMode -eq 'file-error') { throw 'fixture download failure' }
        if ($global:floatingUrlbarRemoteMode -eq 'real') { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $OutFile }
        elseif ($file -eq 'install.ps1') { Copy-Item "$remoteFixture/install.ps1" $OutFile }
        else { Set-Content -LiteralPath $OutFile -Value 'fixture' }
    }
    foreach ($mode in @('string', 'bytes', 'api-error', 'invalid-revision', 'file-error')) {
        $global:floatingUrlbarRemoteMode = $mode
        $global:floatingUrlbarRemoteDownloads = @()
        Remove-Item -LiteralPath $remoteTrace -ErrorAction SilentlyContinue
        $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'floating-urlbar-remote-*' | ForEach-Object Name)
        if ($mode -in @('string', 'bytes')) {
            & "$repo/install-remote.ps1" -Uninstall -RemoveSharedAutoconfig -ProfilePath 'temporary profile with spaces'
            $trace = Get-Content -LiteralPath $remoteTrace -Raw | ConvertFrom-Json
            Assert-That ($trace.Cleanup -and $trace.Uninstall -and $trace.ProfilePath -eq 'temporary profile with spaces') 'lean launcher lost cleanup arguments'
            Assert-That (($global:floatingUrlbarRemoteDownloads -join ',') -eq 'install.ps1,fx-autoconfig.conf,JS/replace-new-tab.uc.js,CSS/firefox-floating-urlbar.uc.css') 'lean launcher downloaded unexpected files'
        } else {
            Assert-Rejected { & "$repo/install-remote.ps1" } "accepted $mode"
            Assert-That (-not (Test-Path -LiteralPath $remoteTrace)) "executed installer after $mode"
        }
        $after = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'floating-urlbar-remote-*' | ForEach-Object Name)
        Assert-That (($before -join ',') -eq ($after -join ',')) "$mode remote launcher left temporary files"
    }
    # Execute the actual downloaded script against a temporary external loader.
    $global:floatingUrlbarRemoteMode = 'real'
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
    Remove-Variable -Scope Global -Name floatingUrlbarRemoteMode, floatingUrlbarRemoteDownloads -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
# Expected failing child processes must not become the suite's exit code.
exit 0
