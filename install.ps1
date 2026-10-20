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

function Backup-File([string]$Path) {
    Assert-Destination $Path
    $backup = "$Path.bak-$(Get-Date -Format yyyyMMddHHmmss)-$([Guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Path -Destination $backup
    Write-Host "  Backed up $Path to $backup"
    return $backup
}

function Copy-WithBackup([string]$Source, [string]$Destination) {
    Assert-Destination $Destination
    if ((Test-Path -LiteralPath $Destination) -and
        (Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash) {
        $null = Backup-File $Destination
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

function Install-Payloads([string]$SelectedProfile, [Collections.IDictionary]$Payloads) {
    foreach ($path in @('chrome', 'chrome/JS', 'chrome/CSS')) {
        Assert-Destination (Join-Path $SelectedProfile $path) -Directory
    }
    $staging = Join-Path $SelectedProfile "chrome/.floating-urlbar-install.$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $entries = @()
    $applied = @()
    try {
        foreach ($source in $Payloads.Keys) {
            $destination = Join-Path $SelectedProfile $Payloads[$source]
            Assert-Destination $destination
            $sourcePath = Join-Path $PSScriptRoot $source
            if ((Test-Path -LiteralPath $destination) -and
                (Get-FileHash -LiteralPath $sourcePath).Hash -eq (Get-FileHash -LiteralPath $destination).Hash) { continue }
            $staged = Join-Path $staging $source
            [IO.Directory]::CreateDirectory((Split-Path $staged -Parent)) | Out-Null
            if (Test-Path -LiteralPath $destination) { Copy-Item -LiteralPath $destination -Destination $staged }
            Copy-Item -LiteralPath $sourcePath -Destination $staged
            $entries += [pscustomobject]@{ Destination = $destination; Staged = $staged; Backup = '' }
        }
        foreach ($entry in $entries) {
            if (Test-Path -LiteralPath $entry.Destination) { $entry.Backup = Backup-File $entry.Destination }
        }
        foreach ($entry in $entries) {
            Assert-Destination (Join-Path $SelectedProfile 'chrome') -Directory
            Assert-Destination (Split-Path $entry.Destination -Parent) -Directory
            Assert-Destination $entry.Destination
            $applied += $entry
            Move-Item -LiteralPath $entry.Staged -Destination $entry.Destination -Force
        }
    } catch {
        $failure = $_
        for ($i = $applied.Count - 1; $i -ge 0; $i--) {
            $entry = $applied[$i]
            try {
                Assert-Destination (Join-Path $SelectedProfile 'chrome') -Directory
                Assert-Destination (Split-Path $entry.Destination -Parent) -Directory
                Assert-Destination $entry.Destination
                if ($entry.Backup) { Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force }
                elseif (Test-Path -LiteralPath $entry.Destination) { Remove-Item -LiteralPath $entry.Destination }
            } catch { Write-Warning "Could not restore $($entry.Destination); backup: $($entry.Backup). $($_.Exception.Message)" }
        }
        throw $failure
    } finally { Remove-Item -LiteralPath $staging -Recurse -Force }
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
    try {
        $firstPath = Get-NormalizedProfilePath $First
        $secondPath = Get-NormalizedProfilePath $Second
    } catch { return $false }
    if ($firstPath -eq $secondPath) { return $true }
    if ($env:OS -ne 'Windows_NT') { return $false }
    # One read-only lookup canonicalizes 8.3 spellings to the same key.
    try {
        $files = New-Object -ComObject Scripting.FileSystemObject
        return $files.GetFolder($firstPath).ShortPath -eq $files.GetFolder($secondPath).ShortPath
    } catch { return $false }
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
    if ($PreferredProfile -and (Test-Path -LiteralPath (Join-Path $PreferredProfile 'prefs.js') -PathType Leaf)) {
        # Trailing separators and 8.3 spellings must not add a duplicate row.
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
    $receipt = Join-Path $Directory '.floating-urlbar-autoconfig'
    Assert-Destination $receipt
    if (-not (Test-Path -LiteralPath "$Directory/config.js") -and -not (Test-Path -LiteralPath "$prefs/config-prefs.js")) {
        $sourceReceipt = Join-Path $Source '.floating-urlbar-autoconfig'
        Write-AutoconfigReceipt $sourceReceipt $Source $files
        Copy-Item -LiteralPath $sourceReceipt -Destination $receipt
    }
    # config.js must exist before the preferences activate it.
    foreach ($file in $files) {
        $destination = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath (Join-Path $Source $file) -Destination $destination
        }
    }
}

function Write-AutoconfigReceipt([string]$Receipt, [string]$Base, [string[]]$Files) {
    $lines = foreach ($file in $Files) { "$( (Get-FileHash -LiteralPath (Join-Path $Base $file) -Algorithm SHA256).Hash ) $file" }
    Set-Content -LiteralPath $Receipt -Value $lines -Encoding ASCII
}

function Assert-AutoconfigReceipt([string]$Receipt, [string]$Base, [string[]]$Files) {
    $recovery = if ([IO.Path]::GetFileName($Receipt) -eq '.floating-urlbar-autoconfig') {
        'Shared startup ownership cannot be restored by reinstalling; inspect these files manually after checking other profiles and users.'
    } else {
        'Reinstall to restore a managed profile receipt using verified upstream files; locally edited files remain protected.'
    }
    Assert-Destination $Receipt
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf)) { throw "No ownership record for $Base; keeping fx-autoconfig. $recovery" }
    $seen = @()
    foreach ($line in Get-Content -LiteralPath $Receipt) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) (.+)$') { throw "Invalid ownership record: $Receipt. $recovery" }
        $hash = $Matches[1]
        $file = $Matches[2]
        if ($file -cnotin $Files -or $file -cin $seen) { throw "Unexpected ownership entry: $file" }
        $seen += $file
        $path = Join-Path $Base $file
        Assert-Destination $path
        if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash) {
            throw "Locally changed fx-autoconfig file; keeping the loader: $path"
        }
    }
    if ($seen.Count -ne $Files.Count) { throw "Incomplete ownership record: $Receipt. $recovery" }
}

function Remove-SharedAutoconfig([string]$Directory) {
    foreach ($path in @('defaults', 'defaults/pref')) { Assert-Destination (Join-Path $Directory $path) -Directory }
    $files = @('config.js', 'defaults/pref/config-prefs.js')
    $present = $false
    foreach ($file in $files + @('.floating-urlbar-autoconfig')) {
        $path = Join-Path $Directory $file
        Assert-Destination $path
        if (Test-Path -LiteralPath $path) { $present = $true }
    }
    if (-not $present) { return }
    Assert-AutoconfigReceipt "$Directory/.floating-urlbar-autoconfig" $Directory $files
    # Disable AutoConfig before removing its script.
    foreach ($file in @('defaults/pref/config-prefs.js', 'config.js', '.floating-urlbar-autoconfig')) {
        $path = Join-Path $Directory $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Remove-ManagedAutoconfig([string]$SelectedProfile, [string]$ExplicitDirectory, [bool]$Shared) {
    $utils = Join-Path $SelectedProfile 'chrome/utils'
    Assert-Destination "$SelectedProfile/chrome" -Directory
    Assert-Destination $utils -Directory
    Assert-Destination "$utils/.floating-urlbar-source"
    $owned = Test-Path -LiteralPath "$utils/.floating-urlbar-source" -PathType Leaf
    $files = @('chrome.manifest') + $AutoconfigModules + @('fx-autoconfig.LICENSE', 'fx-autoconfig.txt')
    if ($owned) { Assert-AutoconfigReceipt "$utils/.floating-urlbar-files" $utils $files }
    if (Test-Path -LiteralPath $utils) {
        foreach ($item in Get-ChildItem -LiteralPath $utils -Force) {
            if ($item.Name -like '*.bak-*') { continue }
            if (-not $owned) { throw 'This loader was not installed by us; keeping fx-autoconfig.' }
            if ($item.Name -cnotin ($files + @('.floating-urlbar-source', '.floating-urlbar-files'))) {
                throw "Other loader file found; keeping fx-autoconfig: $($item.FullName)"
            }
        }
    }
    $sharedPresent = $false
    if ($Shared) {
        $directory = Find-FirefoxDirectory $SelectedProfile $ExplicitDirectory
        foreach ($path in @('defaults', 'defaults/pref')) { Assert-Destination (Join-Path $directory $path) -Directory }
        foreach ($file in @('config.js', 'defaults/pref/config-prefs.js', '.floating-urlbar-autoconfig')) {
            Assert-Destination (Join-Path $directory $file)
            if (Get-ExistingItem (Join-Path $directory $file)) { $sharedPresent = $true }
        }
    }
    if (-not $owned -and -not $sharedPresent) {
        return
    }
    if (Test-Path -LiteralPath "$SelectedProfile/chrome" -PathType Container) {
        $chrome = Get-Item -LiteralPath "$SelectedProfile/chrome" -Force
        $chromePath = $chrome.FullName
        $utilsPath = Join-Path $chromePath 'utils'
        foreach ($item in Get-ChildItem -LiteralPath $chromePath -Recurse -Force) {
            # Do not follow links into other profiles or customizations.
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked customization; keeping fx-autoconfig: $($item.FullName)" }
            $nativeStyle = -not $item.PSIsContainer -and [string]::Equals($item.DirectoryName, $chromePath, [StringComparison]::OrdinalIgnoreCase) -and
                $item.Name -cin @('userChrome.css', 'userContent.css')
            if (-not $item.PSIsContainer -and -not $nativeStyle -and -not [string]::Equals($item.DirectoryName, $utilsPath, [StringComparison]::OrdinalIgnoreCase) -and $item.Extension -in @('.js', '.mjs', '.css')) {
                throw "Other customization found; keeping fx-autoconfig: $($item.FullName)"
            }
        }
    }
    if ($sharedPresent) {
        try { Remove-SharedAutoconfig $directory }
        catch [UnauthorizedAccessException] {
            $quotedScript = $PSCommandPath.Replace("'", "''")
            $quotedDirectory = $directory.Replace("'", "''")
            $invocation = "& '$quotedScript' -StartupOnly -RemoveSharedAutoconfig -FirefoxDirectory '$quotedDirectory'"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
            try {
                $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
            } catch {
                throw "Shared fx-autoconfig removal failed or elevation was cancelled: $($_.Exception.Message)"
            }
            if ($process.ExitCode -ne 0) { throw 'Shared fx-autoconfig removal failed or elevation was cancelled.' }
            foreach ($file in @('config.js', 'defaults/pref/config-prefs.js', '.floating-urlbar-autoconfig')) {
                if (Test-Path -LiteralPath (Join-Path $directory $file)) { throw "Elevated removal left a startup file: $file" }
            }
        }
    }
    if ($owned) {
        foreach ($file in $files + @('.floating-urlbar-source', '.floating-urlbar-files')) {
            $path = Join-Path $utils $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if (@(Get-ChildItem -LiteralPath $utils -Force).Count -eq 0) { Remove-Item -LiteralPath $utils }
        Write-Host 'Removed our fx-autoconfig profile loader.'
    }
    if (-not $Shared) { Write-Host 'Shared Firefox startup files remain; -RemoveSharedAutoconfig also removes files we created for all profiles.' }
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
    Assert-Destination "$utils/.floating-urlbar-files"
    $files = @('chrome.manifest') + $AutoconfigModules + @('fx-autoconfig.LICENSE', 'fx-autoconfig.txt')
    $receiptComplete = $false
    try {
        Assert-AutoconfigReceipt "$utils/.floating-urlbar-files" $utils $files
        $receiptComplete = $true
    } catch { }
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
            (Test-Path -LiteralPath "$utils/fx-autoconfig.txt" -PathType Leaf) -and
            $receiptComplete) { return }
        $repairOnly = $true
    }
    if ((Test-Path -LiteralPath $utils) -and -not (Test-Path -LiteralPath $marker) -and
        @(Get-ChildItem -LiteralPath $utils -Force | Where-Object { $_.Name -notlike '*.bak-*' }).Count) {
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
        if (-not $repairOnly -or -not $receiptComplete) {
            $receipt = Join-Path $temp 'owned-files'
            Copy-Item -LiteralPath "$source/LICENSE" -Destination "$source/profile/chrome/utils/fx-autoconfig.LICENSE"
            Copy-Item -LiteralPath "$source/fx-autoconfig.txt" -Destination "$source/profile/chrome/utils/fx-autoconfig.txt"
            Write-AutoconfigReceipt $receipt "$source/profile/chrome/utils" $files
            Copy-Item -LiteralPath $receipt -Destination "$utils/.floating-urlbar-files"
        }
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

function Read-CleanupConfirmation([string]$Prompt) {
    try { return (Read-Host $Prompt) -match '^(?i:y|yes)$' }
    catch { Write-Warning 'Could not read cleanup confirmation; keeping fx-autoconfig.'; return $false }
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
    Assert-Destination $stateDirectory -Directory
    Assert-Destination $stateFile
    if (-not $ProfilePath) {
        $preferredProfile = ''
        if ($Uninstall -and -not $Root -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
            $saved = "$(Get-Content -LiteralPath $stateFile -Raw)".Trim()
            if ([IO.Path]::IsPathRooted($saved) -and (Test-Path -LiteralPath (Join-Path $saved 'prefs.js') -PathType Leaf)) {
                $preferredProfile = $saved
            }
        }
        if (-not $Root) { $Root = Join-Path $env:APPDATA 'Mozilla/Firefox' }
        $ProfilePath = Select-FirefoxProfile $Root $preferredProfile
    }
    $ProfilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
    Assert-Destination $ProfilePath -Directory
    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePath 'prefs.js') -PathType Leaf)) {
        throw "Not an initialized Firefox profile: $ProfilePath. Start Firefox once first."
    }
    foreach ($path in @('chrome', 'chrome/JS', 'chrome/CSS')) {
        Assert-Destination (Join-Path $ProfilePath $path) -Directory
    }
    $payloads = [ordered]@{
        'JS/replace-new-tab.uc.js' = 'chrome/JS/replace-new-tab.uc.js'
        'CSS/firefox-floating-urlbar.uc.css' = 'chrome/CSS/firefox-floating-urlbar.uc.css'
    }
    foreach ($path in $payloads.Values) { Assert-Destination (Join-Path $ProfilePath $path) }
    if (@(Get-Process -Name firefox -ErrorAction SilentlyContinue).Count) {
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
                if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $source)).Hash) {
                    Copy-Item -LiteralPath $destination -Destination "$destination.bak-$([Guid]::NewGuid().ToString('N'))"
                }
                Remove-Item -LiteralPath $destination
            }
        }
        # Payload removal is complete even when optional loader cleanup refuses.
        $savedProfile = ''
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) { $savedProfile = "$(Get-Content -LiteralPath $stateFile -Raw)".Trim() }
        if ($savedProfile -and [IO.Path]::IsPathRooted($savedProfile) -and (Test-SameProfilePath $savedProfile $ProfilePath)) {
            Remove-Item -LiteralPath $stateFile
        }
        $cleanup = $RemoveAutoconfig -or $RemoveSharedAutoconfig
        $sharedCleanup = [bool]$RemoveSharedAutoconfig
        if (-not $cleanup -and -not [Console]::IsInputRedirected -and [Environment]::UserInteractive -and
            (Test-Path -LiteralPath "$ProfilePath/chrome/utils/.floating-urlbar-source" -PathType Leaf)) {
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
        Write-Host "Installed into $ProfilePath"
    }
    Write-Host 'Clear the startup cache through about:support and restart Firefox.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-FloatingUrlbarInstall }
    catch { Write-Error $_; exit 1 }
}
