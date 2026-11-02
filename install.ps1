[CmdletBinding()]
param(
    [string]$ProfilePath,
    [string]$Root,
    [string]$FirefoxDirectory,
    [switch]$Uninstall,
    [switch]$RemoveAutoconfig,
    [switch]$RemoveSharedAutoconfig,
    [switch]$StartupOnly,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AutoconfigPin = ConvertFrom-StringData (Get-Content -LiteralPath "$PSScriptRoot/fx-autoconfig.conf" -Raw)
$AutoconfigModules = @('boot.sys.mjs', 'fs.sys.mjs', 'utils.sys.mjs', 'uc_api.sys.mjs', 'module_loader.mjs')

$AutoconfigFiles = @('chrome.manifest') + $AutoconfigModules + @('fx-autoconfig.LICENSE', 'fx-autoconfig.txt')
# config.js comes first: config-prefs.js activates it.
$StartupFiles = @('config.js', 'defaults/pref/config-prefs.js')
# Our loader in chrome/utils: holds the installed fx-autoconfig commit.
$ProfileMarker = '.floating-urlbar-source'
# Our startup files in the Firefox directory.
$SharedMarker = '.floating-urlbar-autoconfig'

# .NET methods wrap access errors, so match the whole exception chain.
function Test-AccessDenied([Exception]$Exception) {
    for ($current = $Exception; $current; $current = $current.InnerException) {
        if ($current -is [UnauthorizedAccessException]) { return $true }
    }
    return $false
}

# PowerShell also treats typographic quotes as single quotes.
function ConvertTo-QuotedArgument([string]$Value) {
    return "'$([Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value))'"
}

function Test-SameContent([string]$First, [string]$Second) {
    return (Test-Path -LiteralPath $Second -PathType Leaf) -and
        (Get-FileHash -LiteralPath $First).Hash -eq (Get-FileHash -LiteralPath $Second).Hash
}

function Backup-File([string]$Path) {
    $backup = "$Path.bak-$(Get-Date -Format yyyyMMddHHmmss)-$([Guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Path -Destination $backup
    Write-Host "  Backed up $Path to $backup"
}

# Installation is idempotent: after a failure, rerunning the installer finishes it.
function Install-Payloads([string]$SelectedProfile, [Collections.IDictionary]$Payloads) {
    foreach ($source in $Payloads.Keys) {
        $sourcePath = Join-Path $PSScriptRoot $source
        $destination = Join-Path $SelectedProfile $Payloads[$source]
        if (Test-SameContent $sourcePath $destination) { continue }
        if (Test-Path -LiteralPath $destination) { Backup-File $destination }
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
        Write-Host "  installed $(Split-Path $destination -Leaf)"
    }
}

function Get-NormalizedProfilePath([string]$Path) {
    if (-not $Path) { return '' }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # Preserve drive roots such as C:\.
    if ($resolved.Length -gt 3) { $resolved = $resolved.TrimEnd('\', '/') }
    return $resolved
}

function Test-SameProfilePath([string]$First, [string]$Second) {
    if (-not $First -or -not $Second) { return $false }
    try { return [string]::Equals((Get-NormalizedProfilePath $First), (Get-NormalizedProfilePath $Second), [StringComparison]::OrdinalIgnoreCase) }
    catch { return $false }
}

function Get-FirefoxProfiles([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $entries = @()
    $current = $null
    $ini = Join-Path $Directory 'profiles.ini'
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in Get-Content -LiteralPath $ini -Encoding UTF8) {
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
        # Join-Path fails for absolute profiles on a missing drive.
        if (Test-Path -LiteralPath ([IO.Path]::Combine($path, 'prefs.js'))) {
            # Use the same form as the remembered path.
            $path = Get-NormalizedProfilePath $path
            $found = $true
            [pscustomobject]@{ Name = $entry['Name']; Path = $path; Raw = $entry['Path'] }
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

function Select-FirefoxProfile([string]$Directory, [string]$PreferredProfile = '') {
    $profiles = @(Get-FirefoxProfiles $Directory)
    $preferredIndex = -1
    if ($PreferredProfile -and (Test-Path -LiteralPath ([IO.Path]::Combine($PreferredProfile, 'prefs.js')) -PathType Leaf)) {
        # Trailing separators must not add a duplicate row.
        $preferredPath = Get-NormalizedProfilePath $PreferredProfile
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            if (Test-SameProfilePath $profiles[$i].Path $preferredPath) { $preferredIndex = $i; break }
        }
        if ($preferredIndex -lt 0) {
            $preferredIndex = $profiles.Count
            $profiles += [pscustomobject]@{ Name = "$(Split-Path $preferredPath -Leaf) (last installed)"; Path = $preferredPath; Raw = '' }
        }
    }
    if ($profiles.Count -eq 0) { throw "No initialized Firefox profiles found in $Directory. Start Firefox once first." }
    if ($profiles.Count -eq 1) { return $profiles[0].Path }
    $default = ''
    foreach ($ini in @('installs.ini', 'profiles.ini')) {
        $path = Join-Path $Directory $ini
        if (Test-Path -LiteralPath $path) {
            $installSection = $ini -eq 'installs.ini'
            foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
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
    if ($preferredIndex -ge 0) { $defaultIndex = $preferredIndex }
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
            $match = @(Get-Content -LiteralPath $compatibility -Encoding UTF8 | Select-String '^LastPlatformDir=(.+)$')
            if ($match.Count) { $candidates += $match[0].Matches[0].Groups[1].Value }
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if ($base) { $candidates += Join-Path $base 'Mozilla Firefox' }
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath ([IO.Path]::Combine($candidate, 'firefox.exe')) -PathType Leaf)) {
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

# Reruns this script elevated for one Firefox-directory operation; profile writes stay with the user.
function Invoke-ElevatedStartup([string]$Arguments, [string]$Action) {
    $invocation = "& $(ConvertTo-QuotedArgument $PSCommandPath) -StartupOnly $Arguments"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    try {
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    } catch {
        throw "$Action failed or elevation was cancelled: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) { throw "$Action failed or elevation was cancelled." }
}

function Install-StartupFiles([string]$Source, [string]$Directory) {
    # Firefox reads only one AutoConfig file; LibreWolf and others ship their own.
    $prefs = Join-Path $Directory 'defaults/pref'
    if (Test-Path -LiteralPath $prefs) {
        foreach ($file in Get-ChildItem -LiteralPath $prefs -Filter '*.js' -File) {
            if ($file.Name -ne 'config-prefs.js' -and
                (Select-String -LiteralPath $file.FullName -Pattern 'general\.config\.(filename|sandbox_enabled|obscure_value)' -Quiet)) {
                throw "Another AutoConfig configuration exists: $($file.FullName). It will not be overwritten."
            }
        }
    }
    $marker = Join-Path $Directory $SharedMarker
    $owned = Test-Path -LiteralPath $marker
    $needed = $false
    $existing = $false
    foreach ($file in $StartupFiles) {
        $destination = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $destination)) { $needed = $true; continue }
        $existing = $true
        if (-not (Test-SameContent (Join-Path $Source $file) $destination)) {
            if (-not $owned) { throw "Existing AutoConfig startup file was not installed by this project: $destination. Remove or merge it first." }
            $needed = $true
        }
    }
    if (-not $needed) { return }
    Write-Host "Setting up shared AutoConfig startup files in $Directory for ALL profiles (config.js and defaults/pref/config-prefs.js; AutoConfig sandbox disabled)."
    [IO.Directory]::CreateDirectory($prefs) | Out-Null
    foreach ($file in $StartupFiles) {
        Copy-Item -LiteralPath (Join-Path $Source $file) -Destination (Join-Path $Directory $file) -Force
    }
    # Startup files we did not create stay unowned, so uninstall never removes them.
    if ($owned -or -not $existing) { Set-Content -LiteralPath $marker -Value $StartupFiles -Encoding ASCII }
}

function Remove-SharedAutoconfig([string]$Directory) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory $SharedMarker))) {
        Write-Host "Shared AutoConfig startup files in $Directory were not installed by us; keeping them."
        return
    }
    # Disable AutoConfig before removing its script. This affects all profiles.
    foreach ($file in @('defaults/pref/config-prefs.js', 'config.js', $SharedMarker)) {
        $path = Join-Path $Directory $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host "Removed shared AutoConfig startup files from $Directory."
}

function Remove-ManagedAutoconfig([string]$SelectedProfile, [string]$ExplicitDirectory, [bool]$Shared) {
    $chrome = Join-Path $SelectedProfile 'chrome'
    $utils = Join-Path $chrome 'utils'
    # Other scripts and styles may depend on this loader, even after our two files go.
    if (Test-Path -LiteralPath $chrome -PathType Container) {
        $chromePath = (Get-Item -LiteralPath $chrome -Force).FullName
        $other = @(Get-ChildItem -LiteralPath $chromePath -Recurse -File -Force | Where-Object {
            $_.Extension -in @('.js', '.mjs', '.css') -and $_.DirectoryName -ne (Join-Path $chromePath 'utils') -and
                -not ($_.DirectoryName -eq $chromePath -and $_.Name -in @('userChrome.css', 'userContent.css'))
        })
        if ($other.Count) { throw "Other customization found; keeping fx-autoconfig: $($other[0].FullName)" }
    }
    if ($Shared) {
        $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory
        try { Remove-SharedAutoconfig $directory }
        catch {
            if (-not (Test-AccessDenied $_.Exception)) { throw }
            Invoke-ElevatedStartup "-RemoveSharedAutoconfig -FirefoxDirectory $(ConvertTo-QuotedArgument $directory)" 'Shared fx-autoconfig removal'
        }
    }
    if (Test-Path -LiteralPath (Join-Path $utils $ProfileMarker)) {
        # .floating-urlbar-files is the hash receipt written by older versions.
        foreach ($file in $AutoconfigFiles + @($ProfileMarker, '.floating-urlbar-files')) {
            $path = Join-Path $utils $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if (@(Get-ChildItem -LiteralPath $utils -Force).Count -eq 0) { Remove-Item -LiteralPath $utils }
        Write-Host 'Removed our fx-autoconfig profile loader.'
    } else {
        Write-Host 'The fx-autoconfig profile loader was not installed by us; keeping it.'
    }
    if (-not $Shared) { Write-Host 'Shared Firefox startup files remain; -RemoveSharedAutoconfig also removes files we created for all profiles.' }
}

function Test-AutoconfigCurrent([string]$Utils, [string]$Directory) {
    $marker = Join-Path $Utils $ProfileMarker
    if (-not (Test-Path -LiteralPath $marker) -or
        "$(Get-Content -LiteralPath $marker -TotalCount 1)".Trim() -ne $AutoconfigPin.AUTOCONFIG_COMMIT) { return $false }
    foreach ($file in $AutoconfigFiles) { if (-not (Test-Path -LiteralPath (Join-Path $Utils $file))) { return $false } }
    foreach ($file in $StartupFiles) { if (-not (Test-Path -LiteralPath (Join-Path $Directory $file))) { return $false } }
    return $true
}

function Ensure-Autoconfig([string]$SelectedProfile, [string]$ExplicitDirectory) {
    $utils = Join-Path $SelectedProfile 'chrome/utils'
    $marker = Join-Path $utils $ProfileMarker
    $owned = Test-Path -LiteralPath $marker
    if (-not $owned -and (Test-Path -LiteralPath (Join-Path $utils 'boot.sys.mjs')) -and
        (Test-Path -LiteralPath (Join-Path $utils 'chrome.manifest'))) {
        Write-Host 'Using existing fx-autoconfig profile loader.'
        return
    }
    if (-not $owned -and (Test-Path -LiteralPath $utils) -and @(Get-ChildItem -LiteralPath $utils -Force).Count) {
        throw "Existing incomplete loader in $utils; restore or move it aside before installing."
    }
    $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory
    if (Test-AutoconfigCurrent $utils $directory) { return }
    $temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    try {
        $archive = Join-Path $temp 'source.zip'
        Write-Host 'Downloading verified fx-autoconfig snapshot...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri "https://codeload.github.com/MrOtherGuy/fx-autoconfig/zip/$($AutoconfigPin.AUTOCONFIG_COMMIT)" -OutFile $archive
        $source = Expand-AutoconfigArchive $archive (Join-Path $temp 'source')
        foreach ($file in @('LICENSE') + ($StartupFiles | ForEach-Object { "program/$_" }) +
            (@('chrome.manifest') + $AutoconfigModules | ForEach-Object { "profile/chrome/utils/$_" })) {
            if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { throw "fx-autoconfig source is incomplete: $file" }
        }
        try { Install-StartupFiles (Join-Path $source 'program') $directory }
        catch {
            if (-not (Test-AccessDenied $_.Exception)) { throw }
            # The elevated copy verifies the archive again before writing.
            Invoke-ElevatedStartup "-FirefoxDirectory $(ConvertTo-QuotedArgument $directory) -ArchivePath $(ConvertTo-QuotedArgument $archive)" 'Firefox startup-file installation'
        }
        foreach ($path in @($utils, (Join-Path $SelectedProfile 'chrome/resources'))) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        # The marker goes first, so an interrupted copy is still recognized as ours.
        Set-Content -LiteralPath $marker -Value 'pending' -Encoding ASCII
        foreach ($file in @('chrome.manifest') + $AutoconfigModules) {
            Copy-Item -LiteralPath "$source/profile/chrome/utils/$file" -Destination (Join-Path $utils $file) -Force
        }
        Copy-Item -LiteralPath "$source/LICENSE" -Destination (Join-Path $utils 'fx-autoconfig.LICENSE') -Force
        Set-Content -LiteralPath (Join-Path $utils 'fx-autoconfig.txt') -Encoding ASCII -Value "fx-autoconfig by MrOtherGuy`nLicense: MPL-2.0 (see fx-autoconfig.LICENSE).`nUnmodified source: https://github.com/MrOtherGuy/fx-autoconfig/tree/$($AutoconfigPin.AUTOCONFIG_COMMIT)"
        Set-Content -LiteralPath $marker -Value $AutoconfigPin.AUTOCONFIG_COMMIT -Encoding ASCII
        Write-Host 'fx-autoconfig is ready.'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

function Read-CleanupConfirmation([string]$Prompt) {
    try { return (Read-Host $Prompt) -match '^(?i:y|yes)$' }
    catch { Write-Warning 'Could not read cleanup confirmation; keeping fx-autoconfig.'; return $false }
}

function Clear-StartupCache {
    [CmdletBinding()]
    param([string]$SelectedProfile)
    try {
        if (@(Get-Process -Name firefox, librewolf -ErrorAction SilentlyContinue).Count) {
            throw 'Firefox is running.'
        }
        $caches = @(Join-Path $SelectedProfile 'startupCache')
        # Firefox keeps a roaming profile's caches under the matching local-data path.
        if ($env:APPDATA -and $env:LOCALAPPDATA) {
            $profilePath = Get-NormalizedProfilePath $SelectedProfile
            $roaming = (Get-NormalizedProfilePath (Join-Path $env:APPDATA 'Mozilla/Firefox')) + [IO.Path]::DirectorySeparatorChar
            if ($profilePath.StartsWith($roaming, [StringComparison]::OrdinalIgnoreCase)) {
                $caches += Join-Path (Join-Path $env:LOCALAPPDATA 'Mozilla/Firefox') (Join-Path $profilePath.Substring($roaming.Length) 'startupCache')
            }
        }
        foreach ($cache in $caches) {
            if (-not (Test-Path -LiteralPath $cache -PathType Container)) { continue }
            Remove-Item -LiteralPath $cache -Recurse -Force
            Write-Host "Cleared startup cache: $cache"
        }
    } catch {
        Write-Warning "Startup cache not cleared: $($_.Exception.Message) Clear it through about:support after closing Firefox."
    }
}

function Invoke-FloatingUrlbarInstall {
    foreach ($name in @('ProfilePath', 'Root', 'FirefoxDirectory')) {
        if ($script:PSBoundParameters.ContainsKey($name) -and -not (Get-Variable $name -ValueOnly)) {
            throw "$name must not be empty."
        }
    }
    if ($StartupOnly) {
        if ($RemoveSharedAutoconfig) {
            if (-not $FirefoxDirectory) { throw 'Shared cleanup requires -FirefoxDirectory.' }
            Remove-SharedAutoconfig (Find-FirefoxDirectory '' $FirefoxDirectory)
            return
        }
        if (-not $ArchivePath -or -not $FirefoxDirectory) { throw 'StartupOnly requires ArchivePath and FirefoxDirectory.' }
        $directory = Find-FirefoxDirectory '' $FirefoxDirectory
        $temp = Join-Path ([IO.Path]::GetTempPath()) "floating-urlbar-admin-$([Guid]::NewGuid().ToString('N'))"
        try {
            $source = Expand-AutoconfigArchive $ArchivePath $temp
            Install-StartupFiles (Join-Path $source 'program') $directory
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force } }
        return
    }
    if (($RemoveAutoconfig -or $RemoveSharedAutoconfig) -and -not $Uninstall) { throw 'AutoConfig cleanup requires -Uninstall.' }
    if (-not $env:APPDATA) { throw 'APPDATA is not set. Run this installer on Windows.' }
    $stateDirectory = Join-Path $env:APPDATA 'firefox-floating-urlbar'
    $stateFile = Join-Path $stateDirectory 'profile'
    if (-not $ProfilePath) {
        $preferredProfile = ''
        if ($Uninstall -and -not $Root -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
            $saved = "$(Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8)".Trim()
            if ([IO.Path]::IsPathRooted($saved) -and (Test-Path -LiteralPath ([IO.Path]::Combine($saved, 'prefs.js')) -PathType Leaf)) {
                $preferredProfile = $saved
            }
        }
        if (-not $Root) { $Root = Join-Path $env:APPDATA 'Mozilla/Firefox' }
        $ProfilePath = Select-FirefoxProfile $Root $preferredProfile
    }
    $ProfilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePath 'prefs.js') -PathType Leaf)) {
        throw "Not an initialized Firefox profile: $ProfilePath. Start Firefox once first."
    }
    $payloads = [ordered]@{
        'JS/replace-new-tab.uc.js' = 'chrome/JS/replace-new-tab.uc.js'
        'CSS/firefox-floating-urlbar.uc.css' = 'chrome/CSS/firefox-floating-urlbar.uc.css'
    }
    if (@(Get-Process -Name firefox, librewolf -ErrorAction SilentlyContinue).Count) {
        Write-Warning 'Firefox is running. Restart it after installation or removal.'
    }
    if (-not $Uninstall) {
        Ensure-Autoconfig $ProfilePath $FirefoxDirectory
        foreach ($path in @('chrome/JS', 'chrome/CSS')) {
            [IO.Directory]::CreateDirectory((Join-Path $ProfilePath $path)) | Out-Null
        }
        Install-Payloads $ProfilePath $payloads
    } else {
        foreach ($source in $payloads.Keys) {
            $destination = Join-Path $ProfilePath $payloads[$source]
            if (Test-Path -LiteralPath $destination) {
                if (-not (Test-SameContent (Join-Path $PSScriptRoot $source) $destination)) { Backup-File $destination }
                Remove-Item -LiteralPath $destination -Force
            }
        }
        # Payload removal is complete even when optional loader cleanup refuses.
        $savedProfile = ''
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) { $savedProfile = "$(Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8)".Trim() }
        if ($savedProfile -and [IO.Path]::IsPathRooted($savedProfile) -and (Test-SameProfilePath $savedProfile $ProfilePath)) {
            Remove-Item -LiteralPath $stateFile
        }
        Clear-StartupCache $ProfilePath
        $cleanup = $RemoveAutoconfig -or $RemoveSharedAutoconfig
        $sharedCleanup = [bool]$RemoveSharedAutoconfig
        if (-not $cleanup -and -not [Console]::IsInputRedirected -and [Environment]::UserInteractive -and
            (Test-Path -LiteralPath "$ProfilePath/chrome/utils/$ProfileMarker" -PathType Leaf)) {
            $cleanup = Read-CleanupConfirmation 'Also remove fx-autoconfig installed by us from this profile? [y/N]'
        }
        if ($cleanup) {
            if (-not $sharedCleanup -and -not [Console]::IsInputRedirected -and [Environment]::UserInteractive) {
                $sharedCleanup = Read-CleanupConfirmation 'Also remove our shared startup files? This disables AutoConfig for ALL profiles; choose yes only if none need it. [y/N]'
            }
            Remove-ManagedAutoconfig $ProfilePath $FirefoxDirectory $sharedCleanup
        }
    }
    if ($Uninstall) {
        Write-Host 'Project files removed. Existing or shared fx-autoconfig files are kept unless explicitly selected for cleanup.'
    } else {
        [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
        Set-Content -LiteralPath $stateFile -Value $ProfilePath -Encoding UTF8
        Clear-StartupCache $ProfilePath
        Write-Host "Installed into $ProfilePath"
    }
    Write-Host 'Restart Firefox; if changes do not appear, clear the startup cache through about:support.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-FloatingUrlbarInstall }
    catch { Write-Error $_; exit 1 }
}
