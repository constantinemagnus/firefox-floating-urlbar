[CmdletBinding()]
param(
    [string]$ProfilePath,
    [string]$Root,
    [string]$FirefoxDirectory,
    [switch]$Uninstall,
    [switch]$StartupOnly,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AutoconfigPin = ConvertFrom-StringData (Get-Content -LiteralPath "$PSScriptRoot/fx-autoconfig.conf" -Raw)
$AutoconfigModules = @('boot.sys.mjs', 'fs.sys.mjs', 'utils.sys.mjs', 'uc_api.sys.mjs', 'module_loader.mjs')

function Get-ExistingItem([string]$Path) {
    try { Get-Item -LiteralPath $Path -Force }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
}

function Assert-Destination([string]$Path, [switch]$Directory) {
    $item = Get-ExistingItem $Path
    if ($null -eq $item) { return }
    $link = $item.PSObject.Properties['LinkType']
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($null -ne $link -and $link.Value -eq 'HardLink') -or
        $item.PSIsContainer -ne $Directory.IsPresent) {
        throw "Unsupported destination: $Path. Links and unexpected file types are not changed."
    }
}

function Copy-WithBackup([string]$Source, [string]$Destination) {
    Assert-Destination $Destination
    if ((Test-Path -LiteralPath $Destination) -and
        (Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash) {
        $backup = "$Destination.bak-$(Get-Date -Format yyyyMMddHHmmss)-$([Guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $Destination -Destination $backup
        Write-Host "  Backed up $Destination to $backup"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

function Get-FirefoxProfiles([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $entries = @()
    $current = $null
    $ini = Join-Path $Directory 'profiles.ini'
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini) {
            if ($line -match '^\[Profile\d+\]') {
                $current = @{}
                $entries += $current
            } elseif ($line -match '^\[') { $current = $null }
            elseif ($null -ne $current -and $line -match '=') {
                $parts = $line -split '=', 2
                $current[$parts[0]] = $parts[1]
            }
        }
    }
    $found = $false
    foreach ($entry in $entries) {
        if (-not $entry.ContainsKey('Path')) { continue }
        $path = if ($entry['IsRelative'] -eq '0') { $entry['Path'] }
                else { Join-Path $Directory $entry['Path'] }
        if (Test-Path -LiteralPath (Join-Path $path 'prefs.js')) {
            $found = $true
            [pscustomobject]@{ Name = $entry['Name']; Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path); Raw = $entry['Path'] }
        }
    }
    if (-not $found) {
        foreach ($root in @($Directory, (Join-Path $Directory 'Profiles'))) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($item in Get-ChildItem -LiteralPath $root -Directory -Force) {
                if (Test-Path -LiteralPath (Join-Path $item.FullName 'prefs.js') -PathType Leaf) {
                    [pscustomobject]@{ Name = $item.Name; Path = $item.FullName; Raw = '' }
                }
            }
        }
    }
}

function Select-FirefoxProfile([string]$Directory) {
    $profiles = @(Get-FirefoxProfiles $Directory)
    if ($profiles.Count -eq 0) { throw "No initialized Firefox profiles found in $Directory. Start Firefox once first." }
    if ($profiles.Count -eq 1) { return $profiles[0].Path }
    $default = ''
    foreach ($ini in @('installs.ini', 'profiles.ini')) {
        $path = Join-Path $Directory $ini
        if (Test-Path -LiteralPath $path) {
            $installSection = $ini -eq 'installs.ini'
            foreach ($line in Get-Content -LiteralPath $path) {
                if ($line -match '^\[' -and $ini -eq 'profiles.ini') { $installSection = $line -match '^\[Install' }
                if ($installSection -and $line -match '^Default=(.+)$') { $default = $Matches[1]; break }
            }
            if ($default) { break }
        }
    }
    $defaultIndex = -1
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ($profiles[$i].Raw -eq $default -and $default) { $defaultIndex = $i }
        Write-Host "$($i + 1). $($profiles[$i].Name) ($($profiles[$i].Path))"
    }
    $prompt = if ($defaultIndex -ge 0) { "Select profile (Enter = $($defaultIndex + 1))" } else { 'Select profile' }
    $choice = Read-Host $prompt
    if (-not $choice -and $defaultIndex -ge 0) { return $profiles[$defaultIndex].Path }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $profiles.Count) {
        throw 'Invalid profile selection.'
    }
    return $profiles[$index - 1].Path
}

function Find-FirefoxDirectory([string]$SelectedProfile, [string]$ExplicitDirectory) {
    $candidates = @($ExplicitDirectory)
    if (-not $ExplicitDirectory) {
        $compatibility = Join-Path $SelectedProfile 'compatibility.ini'
        if (Test-Path -LiteralPath $compatibility) {
            $match = @(Get-Content -LiteralPath $compatibility | Select-String '^LastPlatformDir=(.+)$')
            if ($match.Count) { $candidates += $match[0].Matches[0].Groups[1].Value }
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if ($base) { $candidates += Join-Path $base 'Mozilla Firefox' }
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'firefox.exe') -PathType Leaf)) {
            Assert-Destination $candidate -Directory
            return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
        }
    }
    throw 'Cannot find Firefox. Pass -FirefoxDirectory with the folder containing firefox.exe.'
}

function Expand-AutoconfigArchive([string]$Archive, [string]$Destination) {
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $AutoconfigPin.AUTOCONFIG_ZIP_SHA256) {
        throw 'fx-autoconfig checksum mismatch; nothing was installed.'
    }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
    return Join-Path $Destination "fx-autoconfig-$($AutoconfigPin.AUTOCONFIG_COMMIT)"
}

function Install-StartupFiles([string]$Source, [string]$Directory) {
    foreach ($path in @('defaults', 'defaults/pref')) {
        Assert-Destination (Join-Path $Directory $path) -Directory
    }
    $files = @('config.js', 'defaults/pref/config-prefs.js')
    foreach ($file in $files) {
        $destination = Join-Path $Directory $file
        Assert-Destination $destination
        if ((Test-Path -LiteralPath $destination) -and
            (Get-FileHash -LiteralPath (Join-Path $Source $file)).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
            throw "Existing AutoConfig file differs: $destination. It will not be overwritten."
        }
    }
    $prefs = Join-Path $Directory 'defaults/pref'
    if (Test-Path -LiteralPath $prefs) {
        foreach ($file in Get-ChildItem -LiteralPath $prefs -Filter '*.js' -File) {
            if ($file.Name -ne 'config-prefs.js' -and
                (Select-String -LiteralPath $file.FullName -Pattern 'general\.config\.(filename|sandbox_enabled|obscure_value)' -Quiet)) {
                throw "Another AutoConfig configuration exists: $($file.FullName). It will not be overwritten."
            }
        }
    }
    Write-Host "Setting up AutoConfig in $Directory (config.js and defaults/pref/config-prefs.js; AutoConfig sandbox disabled)."
    [IO.Directory]::CreateDirectory($prefs) | Out-Null
    # config.js must exist before the preferences activate it.
    foreach ($file in $files) {
        $destination = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath (Join-Path $Source $file) -Destination $destination
        }
    }
}

function Ensure-Autoconfig([string]$SelectedProfile, [string]$ExplicitDirectory) {
    $utils = Join-Path $SelectedProfile 'chrome/utils'
    $marker = Join-Path $utils '.floating-urlbar-source'
    $ready = (Test-Path -LiteralPath (Join-Path $utils 'boot.sys.mjs')) -and
             (Test-Path -LiteralPath (Join-Path $utils 'chrome.manifest'))
    if ($ready -and -not (Get-ExistingItem $marker)) {
        $directory = $null
        try { $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory }
        catch { Write-Warning "Existing profile loader found, but Firefox's startup configuration could not be checked. Restore it if the loader does not load." }
        if ($directory -and
            (-not (Test-Path -LiteralPath "$directory/config.js" -PathType Leaf) -or
             -not (Test-Path -LiteralPath "$directory/defaults/pref/config-prefs.js" -PathType Leaf))) {
            Write-Warning "Existing profile loader found, but standard AutoConfig startup files are missing in $directory. Restore your loader's startup configuration if it does not load; custom configurations are left unchanged."
        }
        Write-Host 'Using existing fx-autoconfig profile loader.'
        return
    }
    Assert-Destination $utils -Directory
    Assert-Destination (Join-Path $SelectedProfile 'chrome/resources') -Directory
    Assert-Destination $marker
    $complete = @(@('chrome.manifest') + $AutoconfigModules | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $utils $_) -PathType Leaf)
    }).Count -eq 0
    $repairOnly = $false
    if ($complete -and (Test-Path -LiteralPath $marker) -and
        (Get-Content -LiteralPath $marker -Raw).Trim() -eq $AutoconfigPin.AUTOCONFIG_COMMIT) {
        $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory
        if ((Test-Path -LiteralPath "$directory/config.js" -PathType Leaf) -and
            (Test-Path -LiteralPath "$directory/defaults/pref/config-prefs.js" -PathType Leaf) -and
            (Test-Path -LiteralPath "$utils/fx-autoconfig.LICENSE" -PathType Leaf) -and
            (Test-Path -LiteralPath "$utils/fx-autoconfig.txt" -PathType Leaf)) { return }
        $repairOnly = $true
    }
    if ((Test-Path -LiteralPath $utils) -and -not (Test-Path -LiteralPath $marker) -and
        @(Get-ChildItem -LiteralPath $utils -Force).Count) {
        throw "Existing incomplete loader in $utils; restore or move it aside before installing."
    }
    foreach ($file in @('chrome.manifest') + $AutoconfigModules) { Assert-Destination (Join-Path $utils $file) }
    foreach ($file in @('fx-autoconfig.LICENSE', 'fx-autoconfig.txt')) { Assert-Destination (Join-Path $utils $file) }
    $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory
    $temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    try {
        $archive = Join-Path $temp 'source.zip'
        Write-Host 'Downloading verified fx-autoconfig snapshot...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/MrOtherGuy/fx-autoconfig/zip/$($AutoconfigPin.AUTOCONFIG_COMMIT)" -OutFile $archive
        $source = Expand-AutoconfigArchive $archive (Join-Path $temp 'source')
        foreach ($file in @('chrome.manifest') + $AutoconfigModules) {
            if (-not (Test-Path -LiteralPath "$source/profile/chrome/utils/$file" -PathType Leaf)) {
                throw "fx-autoconfig source is incomplete: $file"
            }
        }
        if (-not (Test-Path -LiteralPath "$source/LICENSE" -PathType Leaf)) { throw 'fx-autoconfig source is missing its license.' }
        try { Install-StartupFiles (Join-Path $source 'program') $directory }
        catch [UnauthorizedAccessException] {
            # Elevate only the startup-file operation; profile writes stay under the current user.
            $quotedScript = $PSCommandPath.Replace("'", "''")
            $quotedDirectory = $directory.Replace("'", "''")
            $quotedArchive = $archive.Replace("'", "''")
            $invocation = "& '$quotedScript' -StartupOnly -FirefoxDirectory '$quotedDirectory' -ArchivePath '$quotedArchive'"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
            try {
                $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
            } catch {
                throw "Firefox startup-file installation failed or elevation was cancelled: $($_.Exception.Message)"
            }
            if ($process.ExitCode -ne 0) { throw 'Firefox startup-file installation failed or elevation was cancelled.' }
            foreach ($file in @('config.js', 'defaults/pref/config-prefs.js')) {
                $destination = Join-Path $directory $file
                Assert-Destination $destination
                if (-not (Test-Path -LiteralPath $destination) -or
                    (Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath "$source/program/$file").Hash) {
                    throw "Elevated installation did not create the expected startup file: $destination"
                }
            }
        }
        [IO.Directory]::CreateDirectory($utils) | Out-Null
        # An interrupted install must remain distinguishable from an external loader.
        if (-not $repairOnly) { Set-Content -LiteralPath $marker -Value 'pending' -Encoding ASCII }
        Copy-WithBackup "$source/LICENSE" "$utils/fx-autoconfig.LICENSE"
        Set-Content -LiteralPath "$source/fx-autoconfig.txt" -Encoding ASCII -Value "fx-autoconfig by MrOtherGuy`nLicense: MPL-2.0 (see fx-autoconfig.LICENSE).`nUnmodified source: https://github.com/MrOtherGuy/fx-autoconfig/tree/$($AutoconfigPin.AUTOCONFIG_COMMIT)"
        Copy-WithBackup "$source/fx-autoconfig.txt" "$utils/fx-autoconfig.txt"
        if ($repairOnly) {
            Write-Host 'fx-autoconfig setup repaired.'
            return
        }
        foreach ($path in @('utils', 'JS', 'CSS', 'resources')) {
            [IO.Directory]::CreateDirectory((Join-Path $SelectedProfile "chrome/$path")) | Out-Null
        }
        foreach ($file in @('chrome.manifest') + $AutoconfigModules) {
            Copy-WithBackup "$source/profile/chrome/utils/$file" (Join-Path $utils $file)
        }
        Set-Content -LiteralPath $marker -Value $AutoconfigPin.AUTOCONFIG_COMMIT -Encoding ASCII
        Write-Host 'fx-autoconfig is ready.'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

function Invoke-FloatingUrlbarInstall {
    foreach ($name in @('ProfilePath', 'Root', 'FirefoxDirectory')) {
        if ($script:PSBoundParameters.ContainsKey($name) -and -not (Get-Variable $name -ValueOnly)) {
            throw "$name must not be empty."
        }
    }
    if ($StartupOnly) {
        if (-not $ArchivePath -or -not $FirefoxDirectory) { throw 'StartupOnly requires ArchivePath and FirefoxDirectory.' }
        $directory = Find-FirefoxDirectory '' $FirefoxDirectory
        $temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-admin-$([Guid]::NewGuid().ToString('N'))"
        try {
            $source = Expand-AutoconfigArchive $ArchivePath $temp
            Install-StartupFiles (Join-Path $source 'program') $directory
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force } }
        return
    }
    if (-not $env:APPDATA) { throw 'APPDATA is not set. Run this installer on Windows.' }
    $stateDirectory = Join-Path $env:APPDATA 'firefox-floating-urlbar'
    $stateFile = Join-Path $stateDirectory 'profile'
    if (-not $ProfilePath) {
        if ($Uninstall -and -not $Root -and (Test-Path -LiteralPath $stateFile)) {
            $ProfilePath = (Get-Content -LiteralPath $stateFile -Raw).Trim()
        } else {
            if (-not $Root) { $Root = Join-Path $env:APPDATA 'Mozilla/Firefox' }
            $ProfilePath = Select-FirefoxProfile $Root
        }
    }
    $ProfilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
    Assert-Destination $ProfilePath -Directory
    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePath 'prefs.js') -PathType Leaf)) {
        throw "Not an initialized Firefox profile: $ProfilePath. Start Firefox once first."
    }
    foreach ($path in @('chrome', 'chrome/JS', 'chrome/CSS')) {
        Assert-Destination (Join-Path $ProfilePath $path) -Directory
    }
    $payloads = @{
        'JS/replace-new-tab.uc.js' = 'chrome/JS/replace-new-tab.uc.js'
        'CSS/firefox-floating-urlbar.uc.css' = 'chrome/CSS/firefox-floating-urlbar.uc.css'
    }
    foreach ($path in $payloads.Values) { Assert-Destination (Join-Path $ProfilePath $path) }
    Assert-Destination $stateDirectory -Directory
    Assert-Destination $stateFile
    if (@(Get-Process -Name firefox -ErrorAction SilentlyContinue).Count) {
        Write-Warning 'Firefox is running. Restart it after installation or removal.'
    }
    if (-not $Uninstall) {
        Ensure-Autoconfig $ProfilePath $FirefoxDirectory
        foreach ($path in @('chrome/JS', 'chrome/CSS')) {
            [IO.Directory]::CreateDirectory((Join-Path $ProfilePath $path)) | Out-Null
        }
    }
    foreach ($source in $payloads.Keys) {
        $destination = Join-Path $ProfilePath $payloads[$source]
        if ($Uninstall) {
            if (Test-Path -LiteralPath $destination) {
                if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $source)).Hash) {
                    Copy-Item -LiteralPath $destination -Destination "$destination.bak-$([Guid]::NewGuid().ToString('N'))"
                }
                Remove-Item -LiteralPath $destination
            }
        } else { Copy-WithBackup (Join-Path $PSScriptRoot $source) $destination }
    }
    if ($Uninstall) {
        if ((Test-Path -LiteralPath $stateFile) -and
            (Get-Content -LiteralPath $stateFile -Raw).Trim() -eq $ProfilePath) { Remove-Item -LiteralPath $stateFile }
        Write-Host 'Project files removed. Shared fx-autoconfig files remain installed.'
    } else {
        [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
        Set-Content -LiteralPath $stateFile -Value $ProfilePath -Encoding UTF8
        Write-Host "Installed into $ProfilePath"
    }
    Write-Host 'Clear the startup cache through about:support and restart Firefox.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-FloatingUrlbarInstall }
    catch { Write-Error $_; exit 1 }
}
