#requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $Interactive,
    [switch] $OnlyCodex,
    [switch] $NoActivate,
    [switch] $Activate,
    [switch] $UseExistingMsys2,
    [switch] $Msys2ReadOnly,
    [string[]] $Tools = @(),
    [string] $PackageDirectory,
    [switch] $Offline,
    [switch] $DownloadOnly,
    [ValidatePattern('^[A-Za-z]:[\\/][A-Za-z0-9._\\/-]+$')]
    [string] $Msys2Root,
    [string] $Msys2SearchPath,
    [ValidatePattern('^[A-Za-z]:[\\/][A-Za-z0-9._\\/-]+$')]
    [string] $PlaygroundRoot = (Get-Location).ProviderPath,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string] $RustifiedGitRef = '7a2be2ebfa45cfc5be78e788a820ee145953f36b'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PlaygroundRoot = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\', '/')
if ($PlaygroundRoot -eq [IO.Path]::GetPathRoot($PlaygroundRoot).TrimEnd('\', '/') -or
    $PlaygroundRoot -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\', '/')) {
    throw 'Choose a dedicated installation folder, not a drive root or your user profile.'
}
if ($Activate -and $NoActivate) { throw 'Choose either -Activate or -NoActivate.' }
if ($DownloadOnly -and $Interactive) { throw 'Use -Tools, not -Interactive, to select an offline bundle.' }
if ($RustifiedGitRef -ne '7a2be2ebfa45cfc5be78e788a820ee145953f36b') { throw 'Source overrides are not permitted in locked package mode. Review and update the package recipe instead.' }
$NoActivate = -not $Activate
$installRoot = Join-Path $PlaygroundRoot 'install'
$binDirectory = Join-Path $PlaygroundRoot 'bin'
$configDirectory = Join-Path $PlaygroundRoot 'config'
$cacheDirectory = Join-Path $PlaygroundRoot 'cache'
$msysRoot = Join-Path $installRoot 'msys2'
$headers = @{ 'User-Agent' = 'terminal-setup'; 'Accept' = 'application/vnd.github+json' }
$selectedTools = @($Tools | ForEach-Object { $_.Split(',') })
. (Join-Path $PSScriptRoot 'lib\interactive.ps1')
. (Join-Path $PSScriptRoot 'lib\packages.ps1')
if ($Tools.Count -and $OnlyCodex) { throw 'Choose -Tools or -OnlyCodex, not both.' }
if ($PSBoundParameters.ContainsKey('Tools') -and $selectedTools.Count -eq 0) { throw '-Tools must select at least one tool.' }
if ($Tools.Count -and $Interactive) { throw 'Choose -Tools or -Interactive, not both.' }
foreach ($tool in $selectedTools) {
    if ($tool -notin @((Get-PDInteractiveCatalog -Platform windows).Id)) { throw "Unknown Windows tool selection: $tool" }
}

function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}
function Test-PDSelected {
    param([string] $Id)
    if ($OnlyCodex) { return $Id -eq 'codex' }
    if (-not $Interactive -and $selectedTools.Count -eq 0) { return $true }
    if ($Id -eq 'pwsh' -and $selectedTools -contains 'copilot') { return $true }
    return $selectedTools -contains $Id
}
function Copy-PDManager {
    if ([IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\') -ieq $PSScriptRoot.TrimEnd('\')) { return }
    foreach ($file in @('install.ps1', 'install.sh', 'wezterm.lua')) {
        $destination = Join-Path $PlaygroundRoot $file
        if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $destination }
    }
    foreach ($directory in @('lib', 'packages', 'patches', 'yazi')) {
        $source = Join-Path $PSScriptRoot $directory
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $relative = $file.FullName.Substring($source.Length + 1)
            $destination = Join-Path (Join-Path $PlaygroundRoot $directory) $relative
            if (-not (Test-Path -LiteralPath $destination)) {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
        }
    }
}
function Resolve-PDSelectedTools {
    param([string[]] $SelectedTools)
    $resolved = @($SelectedTools)
    if ($resolved -contains 'copilot' -and $resolved -notcontains 'pwsh') {
        $resolved += 'pwsh'
    }
    return $resolved
}
function Get-GitHubRelease {
    param([string] $Repo, [switch] $StableMsys2)
    $id = switch ($Repo) {
        msys2/msys2-installer { 'msys2' }
        wezterm/wezterm { 'wezterm' }
        aristocratos/btop4win { 'btop' }
        github/copilot-cli { 'copilot' }
        PowerShell/PowerShell { 'pwsh' }
        notepad-plus-plus/notepad-plus-plus { 'notepadpp' }
        ryanoasis/nerd-fonts { 'font' }
        default { throw "No reviewed release is locked for $Repo." }
    }
    $package = Get-PDPackage $id
    return [pscustomobject]@{ tag_name = $package.Version; assets = @([pscustomobject]@{
        name = [IO.Path]::GetFileName(([Uri]$package.Url).AbsolutePath)
        digest = 'sha256:' + $package.Sha256; browser_download_url = $package.Url
    }) }
}
function Save-Asset {
    param([object] $Asset, [object] $Release)
    $expected = $null
    if ($Asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
        $expected = $Matches[1]
    } else {
        $checksumAsset = $Release.assets | Where-Object { $_.name -eq ($Asset.name + '.sha256') } | Select-Object -First 1
        if ($checksumAsset) {
            $checksumResponse = Invoke-WebRequest -UseBasicParsing -Uri $checksumAsset.browser_download_url
            $checksumText = if ($checksumResponse.Content -is [byte[]]) {
                [Text.Encoding]::UTF8.GetString($checksumResponse.Content)
            } else {
                [string]$checksumResponse.Content
            }
            if ($checksumText -match '\b([a-fA-F0-9]{64})\b') { $expected = $Matches[1] }
        }
    }
    if (-not $expected) { throw "No published SHA-256 was found for $($Asset.name)." }
    return (Save-PDLockedFile -Url $Asset.browser_download_url -Sha256 $expected.ToLowerInvariant())
}
function Find-InstalledTool {
    param([string] $Name, [string] $Executable)
    $directory = Join-Path $installRoot $Name
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
    $found = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter $Executable)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -eq 1) { return $found[0].FullName }
    $manifest = Join-Path $PlaygroundRoot 'state\windows-commands.tsv'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $targets = @([IO.File]::ReadAllLines($manifest) | ForEach-Object {
            $parts = $_.Split([char]9, 2)
            if ($parts.Count -eq 2) {
                if ([IO.Path]::IsPathRooted($parts[1])) { [IO.Path]::GetFullPath($parts[1]) }
                else { [IO.Path]::GetFullPath((Join-Path $PlaygroundRoot $parts[1])) }
            }
        })
        $active = @($found | Where-Object { $targets -icontains $_.FullName })
        if ($active.Count -eq 1) { return $active[0].FullName }
    }
    throw "Multiple installed versions of $Name were found, but no unique active version is recorded in $manifest. No version was changed."
}
function Install-ZipTool {
    param([string] $Repo, [string] $Pattern, [string] $Name, [string] $Executable)
    $installed = Find-InstalledTool -Name $Name -Executable $Executable
    if ($installed) {
        Write-Host "[playground] Keeping installed $Name at $installed."
        return $installed
    }
    $release = Get-GitHubRelease -Repo $Repo
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No suitable $Name archive exists in $Repo." }
    $destination = Join-Path (Join-Path $installRoot $Name) $release.tag_name
    if (Test-Path -LiteralPath $destination) { throw "Incomplete installation at $destination. No existing directory was overwritten." }
    $archive = Save-Asset -Asset $asset -Release $release
    $staging = Join-Path (Join-Path $PlaygroundRoot 'tmp') ('package-' + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-PDLockedArchive -File $archive -Archive zip -Destination $staging
        $found = @(Get-ChildItem -LiteralPath $staging -Recurse -File -Filter $Executable)
        if ($found.Count -ne 1) { throw "Expected one $Executable in $Name." }
        $relative = $found[0].FullName.Substring($staging.Length + 1)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Move-Item -LiteralPath $staging -Destination $destination
        return (Join-Path $destination $relative)
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}
function Install-Msys2 {
    $bashPath = Join-Path $msysRoot 'usr\bin\bash.exe'
    if (Test-Path -LiteralPath $bashPath) {
        if (-not (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\pacman.exe')) -or
            -not (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\cygpath.exe'))) {
            throw "$msysRoot does not contain a valid MSYS2 installation."
        }
        return
    }
    $release = Get-GitHubRelease -Repo 'msys2/msys2-installer' -StableMsys2
    $asset = $release.assets | Where-Object { $_.name -match '^msys2-base-x86_64-.*\.sfx\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'No stable x64 MSYS2 base archive was found.' }
    $archive = Save-Asset -Asset $asset -Release $release
    $staging = Join-Path (Join-Path $PlaygroundRoot 'tmp') ('msys2-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        $process = Start-Process -FilePath $archive -ArgumentList @('-y', ('-o' + $staging)) -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "MSYS2 archive extraction failed with exit code $($process.ExitCode)." }
        Move-Item -LiteralPath (Join-Path $staging 'msys64') -Destination $msysRoot
    } finally { Remove-Item -LiteralPath $staging -Recurse -Force }
    if (-not (Test-Path -LiteralPath $bashPath)) { throw "MSYS2 archive did not create $bashPath." }
}
function Test-Msys2Installation {
    param([string] $Path)
    foreach ($relativePath in @('usr\bin\bash.exe', 'usr\bin\pacman.exe', 'usr\bin\cygpath.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relativePath) -PathType Leaf)) { return $false }
    }
    return $true
}
function Find-Msys2UnderPath {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The MSYS2 search folder does not exist: $Path"
    }
    $searchRoot = [IO.Path]::GetFullPath($Path)
    if (Test-Msys2Installation -Path $searchRoot) { return $searchRoot.TrimEnd('\', '/') }
    foreach ($match in (Get-ChildItem -LiteralPath $searchRoot -Directory `
        -Filter 'msys64' -Recurse -Force -ErrorAction SilentlyContinue)) {
        if (Test-Msys2Installation -Path $match.FullName) {
            return [IO.Path]::GetFullPath($match.FullName).TrimEnd('\', '/')
        }
    }
    return $null
}
function Find-SystemMsys2 {
    param([switch] $SearchFixedDrives)
    $candidates = @()
    if ($env:MSYS2_ROOT) { $candidates += $env:MSYS2_ROOT }
    if ($env:SystemDrive) { $candidates += (Join-Path $env:SystemDrive 'msys64') }
    if ($env:USERPROFILE) {
        foreach ($relativePath in @(
            'msys64', 'tools\msys64', 'scoop\apps\msys2\current',
            'scoop\apps\msys64\current'
        )) {
            $candidates += (Join-Path $env:USERPROFILE $relativePath)
        }
    }

    # MSYS2 has no reliable registry entry, so check its conventional folders
    # on each fixed drive as well as executable locations already on PATH.
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
        foreach ($relativePath in @(
            'msys64', 'msys2', 'tools\msys64', 'tools\msys2',
            'dev\msys64', 'apps\msys64'
        )) {
            $candidates += (Join-Path $drive.RootDirectory.FullName $relativePath)
        }
    }
    foreach ($commandName in @('pacman.exe', 'bash.exe', 'cygpath.exe')) {
        foreach ($command in @(Get-Command $commandName -All -ErrorAction SilentlyContinue)) {
            $commandPath = $null
            $pathProperty = $command.PSObject.Properties['Path']
            $sourceProperty = $command.PSObject.Properties['Source']
            if ($pathProperty -and $pathProperty.Value) { $commandPath = $pathProperty.Value }
            elseif ($sourceProperty -and $sourceProperty.Value) { $commandPath = $sourceProperty.Value }
            if ($commandPath) {
                $candidates += (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $commandPath)))
            }
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Msys2Installation -Path $candidate)) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        }
    }
    if ($SearchFixedDrives) {
        Write-Host '[playground] Searching fixed drives for an MSYS2 installation...'
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
            foreach ($match in (Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Directory `
                -Filter 'msys64' -Recurse -Force -ErrorAction SilentlyContinue)) {
                if (Test-Msys2Installation -Path $match.FullName) {
                    return [IO.Path]::GetFullPath($match.FullName).TrimEnd('\', '/')
                }
            }
        }
    }
    return $null
}
function Select-Msys2Root {
    param([string] $DefaultRoot, [switch] $UsePrivateRoot)
    if ($Msys2Root) {
        if (-not (Test-Msys2Installation -Path $Msys2Root)) {
            throw "The requested MSYS2 root does not contain bash, pacman and cygpath: $Msys2Root"
        }
        return [pscustomobject]@{
            Root = [IO.Path]::GetFullPath($Msys2Root).TrimEnd('\', '/')
            PreserveInstalled = $true
        }
    }
    $searchPathParameter = Get-Variable -Name Msys2SearchPath -ValueOnly -Scope 1 -ErrorAction SilentlyContinue
    if ($searchPathParameter) {
        $searchResult = Find-Msys2UnderPath -Path $searchPathParameter
        if (-not $searchResult) {
            throw "No valid MSYS2 installation was found under $searchPathParameter."
        }
        Write-Host "[playground] Reusing MSYS2 found at $searchResult."
        return [pscustomobject]@{ Root = $searchResult; PreserveInstalled = $true }
    }
    if ($UsePrivateRoot) {
        return [pscustomobject]@{
            Root = $DefaultRoot
            PreserveInstalled = (Test-Msys2Installation -Path $DefaultRoot)
        }
    }
    if (-not $UseExistingMsys2) {
        return [pscustomobject]@{ Root = $DefaultRoot; PreserveInstalled = (Test-Msys2Installation -Path $DefaultRoot) }
    }
    $detectedRoot = Find-SystemMsys2 -SearchFixedDrives
    if ($UseExistingMsys2) {
        if (-not $detectedRoot) {
            throw 'No existing MSYS2 installation was found on the fixed drives. Run without -UseExistingMsys2 to install a private copy.'
        }
        Write-Host "[playground] Reusing system MSYS2 at $detectedRoot."
        return [pscustomobject]@{ Root = $detectedRoot; PreserveInstalled = $true }
    }
    return [pscustomobject]@{
        Root = $DefaultRoot
        PreserveInstalled = (Test-Msys2Installation -Path $DefaultRoot)
    }
}
function ConvertTo-Msys2Path {
    param([string] $Path)
    $converted = & (Join-Path $msysRoot 'usr\bin\cygpath.exe') -u -U $Path
    if ($LASTEXITCODE -ne 0) { throw "Could not translate path for MSYS2: $Path" }
    $converted = $converted.Trim()
    if ($converted -eq '/') {
        # A generated launcher may run under a different MSYS root.
        $native = [IO.Path]::GetFullPath($Path)
        return '/proc/cygdrive/' + $native.Substring(0, 1).ToLowerInvariant() + $native.Substring(2).Replace('\', '/')
    }
    return $converted
}
function Initialize-Msys2 {
    param([bool] $PreserveInstalled, [bool] $ReadOnly = $false)
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    $env:PD_MSYS2_PRESERVE_INSTALLED = if ($PreserveInstalled) { '1' } else { '0' }
    $env:PD_MSYS2_READ_ONLY = if ($ReadOnly) { '1' } else { '0' }
    $env:PATH = "$msysRoot\ucrt64\bin;$msysRoot\usr\bin;$env:PATH"
    $env:BASH_ENV = $null
    $homeDirectory = Join-Path $PlaygroundRoot 'state\msys2-home'
    [IO.Directory]::CreateDirectory($homeDirectory) | Out-Null
    $env:HOME = ConvertTo-Msys2Path -Path $homeDirectory
    $env:PD_USER_HOME = ConvertTo-Msys2Path -Path ([Environment]::GetFolderPath('UserProfile'))
    $env:TMPDIR = ConvertTo-Msys2Path -Path (Join-Path $PlaygroundRoot 'tmp')
    if ($PreserveInstalled -and $ReadOnly) {
        Write-Host '[playground] Reusing MSYS2 read-only; selected unavailable tools will fail explicitly.'
    } elseif ($PreserveInstalled) {
        Install-PDLockedMsys2Packages
    } else {
        Invoke-Checked -Program $bash -Arguments @('--noprofile', '--norc', '-c',
            '/usr/bin/pacman-key --init && /usr/bin/pacman-key --populate msys2; result=$?; GNUPGHOME=/etc/pacman.d/gnupg /usr/bin/gpgconf --kill all; exit $result')
        Install-PDLockedMsys2Packages
    }
    $env:PD_MSYS2_PACKAGES_READY = '1'
}
function Install-Codex {
    $codexHome = Join-Path $configDirectory 'codex'
    $codexBin = Join-Path $installRoot 'codex\bin'
    if (Test-Path -LiteralPath (Join-Path $codexBin 'codex.exe') -PathType Leaf) {
        Write-Host '[playground] Keeping installed Codex CLI.'
        return
    }
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    $executable = Install-PDArchive -Id codex -Name codex -Executable 'codex-x86_64-pc-windows-msvc.exe'
    [IO.Directory]::CreateDirectory($codexBin) | Out-Null
    Copy-Item -LiteralPath $executable -Destination (Join-Path $codexBin 'codex.exe')
    if (-not (Test-Path -LiteralPath (Join-Path $codexBin 'codex.exe'))) {
        throw 'The Codex installer did not create codex.exe.'
    }
}
function Configure-Btop {
    param([string] $Executable)
    $toolDirectory = Split-Path -Parent $Executable
    $centralDirectory = Join-Path $configDirectory 'btop'
    [IO.Directory]::CreateDirectory($centralDirectory) | Out-Null
    $central = Join-Path $centralDirectory 'btop.conf'
    $bundled = Join-Path $toolDirectory 'btop.conf'
    if ((Test-Path -LiteralPath $central -PathType Leaf) -and
        (Test-Path -LiteralPath $bundled -PathType Leaf)) {
        if ((Get-FileHash -LiteralPath $central).Hash -cne (Get-FileHash -LiteralPath $bundled).Hash) {
            throw "btop configurations differ: $central and $bundled. Reconcile them explicitly; neither was overwritten."
        }
        if (-not ('PdFileIdentity' -as [type])) {
            Add-Type @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PdFileIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct Identity { public ulong Volume, Low, High; }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle handle, int infoClass, out Identity info, uint size);
    private static Identity Read(string path) {
        using (var file = File.Open(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete)) {
            Identity info;
            if (!GetFileInformationByHandleEx(file.SafeFileHandle, 18, out info,
                (uint)Marshal.SizeOf(typeof(Identity)))) throw new Win32Exception();
            return info;
        }
    }
    public static bool Same(string left, string right) {
        var a = Read(left); var b = Read(right);
        return a.Volume == b.Volume && a.Low == b.Low && a.High == b.High;
    }
}
'@
        }
        if ([PdFileIdentity]::Same($central, $bundled)) {
            Invoke-Checked -Program $Executable -Arguments @('--version')
            return
        }
    }
    if (-not (Test-Path -LiteralPath $central)) {
        if (Test-Path -LiteralPath $bundled) {
            Copy-Item -LiteralPath $bundled -Destination $central
        } else {
            [IO.File]::WriteAllText($central, '')
        }
    }
    # btop4win requires a co-located config; a hard link keeps it editable in config/.
    $link = Join-Path $toolDirectory ('btop-link-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        New-Item -ItemType HardLink -Path $link -Target $central | Out-Null
        if (Test-Path -LiteralPath $bundled) { [IO.File]::Replace($link, $bundled, [NullString]::Value) }
        else { Move-Item -LiteralPath $link -Destination $bundled }
    } finally {
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
    }
    # The portable release links its C++ runtime statically.
    Invoke-Checked -Program $Executable -Arguments @('--version')
}
function Write-WindowsLaunchers {
    $manifest = Join-Path $PlaygroundRoot 'state\windows-commands.tsv'
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split([char]9, 2)
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Za-z0-9+_-]+$' -or $parts[1] -match '[%"\r\n]') {
            throw 'Invalid Windows command manifest entry; no launcher was written for it.'
        }
        $name = $parts[0]
        $target = $parts[1].Replace('/', '\')
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $PlaygroundRoot $target }
        $target = [IO.Path]::GetFullPath($target)
        if (-not $target.StartsWith([IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
            -not $target.StartsWith([IO.Path]::GetFullPath($msysRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows command target escapes the managed root/MSYS2: $target"
        }
        $lines = @(
            '@echo off', 'setlocal', 'set "MSYSTEM=UCRT64"',
            'set "CHERE_INVOKING=1"', 'set "MSYS2_PATH_TYPE=inherit"',
            ('set "PD_MSYS2_ROOT=' + $msysRoot + '"'),
            ('set "PATH=' + $binDirectory + ';' + $msysRoot + '\ucrt64\bin;' + $msysRoot + '\usr\bin;%PATH%"'),
            ('set "XDG_CONFIG_HOME=' + $configDirectory + '"'),
            ('set "XDG_CACHE_HOME=' + $cacheDirectory + '"'),
            ('set "XDG_DATA_HOME=' + $PlaygroundRoot + '\state\data"'),
            ('set "XDG_STATE_HOME=' + $PlaygroundRoot + '\state"'),
            ('set "TEMP=' + $PlaygroundRoot + '\tmp"'),
            ('set "TMP=' + $PlaygroundRoot + '\tmp"'),
            ('set "_ZO_DATA_DIR=' + $PlaygroundRoot + '\state\zoxide"'),
            ('set "HOME=' + $PlaygroundRoot + '\state\home"')
        )
        if ($name -eq 'git') {
            $lines = @($lines | Where-Object { $_ -notmatch '^set "(HOME|XDG_CONFIG_HOME)=' })
        }
        $extra = ''
        switch ($name) {
            'codex' { $lines += 'set "CODEX_HOME=' + $configDirectory + '\codex"' }
            'copilot' {
                $lines += 'set "COPILOT_HOME=' + $configDirectory + '\copilot"'
                $lines += 'set "COPILOT_CACHE_HOME=' + $cacheDirectory + '\copilot"'
                $lines += 'set "COPILOT_AUTO_UPDATE=false"'
                $powerShellExecutable = [Environment]::GetEnvironmentVariable('PD_PWSH_EXE', 'Process')
                if (-not $powerShellExecutable) {
                    $powerShellExecutable = Find-InstalledTool -Name 'powershell' -Executable 'pwsh.exe'
                }
                if (-not $powerShellExecutable) { throw 'The Copilot launcher requires the managed PowerShell 7 executable.' }
                $lines += 'set "PATH=' + (Split-Path -Parent $powerShellExecutable) + ';%PATH%"'
            }
            'code' {
                $lines += 'set "VSCODE_PORTABLE=' + $configDirectory + '\vscode"'
                # The bundled launcher knows VS Code's versioned internal layout.
                $target = Join-Path (Split-Path -Parent $target) 'bin\code.cmd'
                $extra = '--user-data-dir "' + $configDirectory + '\vscode\user-data" --extensions-dir "' + $configDirectory + '\vscode\extensions" '
            }
            'notepad++' { $extra = '-multiInst -settingsDir="' + $configDirectory + '\notepad++" ' }
            'yazi' {
                $lines += 'set "YAZI_CONFIG_HOME=' + $configDirectory + '\yazi"'
                $lines += 'set "YAZI_CACHE_HOME=' + $cacheDirectory + '\yazi"'
                $lines += 'set "YAZI_STATE_HOME=' + $PlaygroundRoot + '\state\yazi"'
                $lines += 'set "XDG_RUNTIME_DIR=' + $PlaygroundRoot + '\tmp"'
                if (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\file.exe') -PathType Leaf) {
                    $lines += 'set "YAZI_FILE_ONE=' + $msysRoot + '\usr\bin\file.exe"'
                }
            }
            'ya' {
                $lines += 'set "YAZI_CONFIG_HOME=' + $configDirectory + '\yazi"'
                $lines += 'set "YAZI_CACHE_HOME=' + $cacheDirectory + '\yazi"'
                $lines += 'set "YAZI_STATE_HOME=' + $PlaygroundRoot + '\state\yazi"'
                $lines += 'set "XDG_RUNTIME_DIR=' + $PlaygroundRoot + '\tmp"'
            }
            'bash' {
                $lines += 'set "BASH_ENV=' + $configDirectory + '\bash\bashrc"'
                $extra = '--rcfile "' + $configDirectory + '\bash\bashrc" '
            }
            'tmux' { $extra = '-S "' + $PlaygroundRoot + '\state\tmux\socket" -f "' + $configDirectory + '\tmux\tmux.conf" ' }
            'rustifiedgit' { $extra = '--use-config-dir "' + $configDirectory + '\rustifiedgit" ' }
            'wezterm' { $extra = '--config-file "' + $configDirectory + '\wezterm\wezterm.lua" ' }
        }
        $lines += '"' + $target + '" ' + $extra + '%*'
        $lines += 'exit /b %errorlevel%'
        $lines = @($lines | ForEach-Object { $_.Replace($PlaygroundRoot.TrimEnd('\'), '%PD_ROOT%') })
        $lines = @('@echo off', 'setlocal', 'for %%I in ("%~dp0..") do set "PD_ROOT=%%~fI"') + $lines
        [IO.File]::WriteAllText(
            (Join-Path $binDirectory ($name + '.cmd')),
            ($lines -join [Environment]::NewLine) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
    }
}
function Update-WezTermMsys2Config {
    $configPath = Join-Path $configDirectory 'wezterm\wezterm.lua'
    if (-not (Test-Path -LiteralPath $configPath)) { return }
    $content = [IO.File]::ReadAllText($configPath)
    $oldBashPath = "root .. '/install/msys2/usr/bin/bash.exe'"
    if (-not $content.Contains($oldBashPath)) { return }
    $helper = @'
local msys2_root = os.getenv('PD_MSYS2_ROOT')
if not msys2_root then
  local path_file = io.open(root .. '/config/path/msys2-root.txt', 'r')
  if path_file then
    msys2_root = path_file:read('*a'):match('^%s*(.-)%s*$')
    path_file:close()
  end
end
msys2_root = (msys2_root or (root .. '/install/msys2')):gsub('\\', '/')
'@
    $content = [regex]::Replace($content, '(?m)^(local root = .*)$', ('$1' + [Environment]::NewLine + $helper))
    $content = $content.Replace($oldBashPath, "msys2_root .. '/usr/bin/bash.exe'")
    $content = $content.Replace("root .. '/install/msys2/ucrt64/bin;'", "msys2_root .. '/ucrt64/bin;'")
    $content = $content.Replace("root .. '/install/msys2/usr/bin;'", "msys2_root .. '/usr/bin;'")
    [IO.File]::WriteAllText($configPath, $content, [Text.UTF8Encoding]::new($false))
}
function Register-WindowsPath {
    $previous = [Environment]::GetEnvironmentVariable('Path', 'User')
    $backup = Join-Path $PlaygroundRoot 'config\path\windows-user-path.before.txt'
    if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllText($backup, [string]$previous) }
    $entries = @($previous -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $binDirectory.TrimEnd('\') })
    [Environment]::SetEnvironmentVariable('Path', (@($binDirectory) + $entries -join ';'), 'User')
    $env:Path = (@($binDirectory) + @($env:Path -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $binDirectory.TrimEnd('\')
    }) -join ';')
    if (-not ('PdPlaygroundEnvironment' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PdPlaygroundEnvironment {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint message, UIntPtr wParam, string lParam,
    uint flags, uint timeout, out UIntPtr result);
}
'@
    }
    $result = [UIntPtr]::Zero
    [PdPlaygroundEnvironment]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result
    ) | Out-Null
}
$selectedTools = @(Resolve-PDSelectedTools -SelectedTools $selectedTools)
if ($DryRun) {
    Write-Host "[playground] Preview only; root: $PlaygroundRoot"
    $plan = @((Get-PDInteractiveCatalog -Platform windows) | Where-Object { Test-PDSelected $_.Id })
    if ($Interactive) { Write-Host '[playground] Tools will be selected interactively.' }
    else { Write-Host ('[playground] Selected tools and dependencies: ' + ($plan.Id -join ', ')) }
    Write-Host "[playground] Use private MSYS2 in $msysRoot unless reuse is explicitly requested."
    Write-Host '[playground] Install missing tools from hash-locked local archives; no rolling updates or custom certificates.'
    if ((Test-PDSelected yazi) -or (Test-PDSelected rustifiedgit)) {
        Write-Host '[playground] Build selected missing Yazi/RustifiedGit from locked offline-vendored sources.'
    }
    if ($DownloadOnly) {
        Write-Host "[playground] Verify an offline bundle in $cacheDirectory without installing tools or profiles."
        exit 0
    }
    Write-Host "[playground] Create CMD and Bash launchers in $binDirectory."
    if ($NoActivate) {
        Write-Host '[playground] Leave profiles and persistent PATH unchanged; generate manual activation files.'
    } else {
        Write-Host '[playground] Persist the Windows user PATH and broadcast the environment change.'
    }
    exit 0
}
if ($DownloadOnly) {
    foreach ($directory in @($cacheDirectory, (Join-Path $PlaygroundRoot 'tmp'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $ids = @('msys2')
    foreach ($id in @('wezterm', 'btop', 'copilot', 'pwsh', 'notepadpp', 'vscode', 'codex')) {
        if (Test-PDSelected $id) { $ids += $id }
    }
    if (Test-PDSelected wezterm) { $ids += 'font' }
    foreach ($feature in @('yazi', 'rustifiedgit')) { if (Test-PDSelected $feature) { $ids += $feature + '-source' } }
    $downloads = @()
    foreach ($id in $ids) { $package = Get-PDPackage $id; $downloads += [pscustomobject]@{Url = $package.Url; Sha256 = $package.Sha256} }
    $downloads += @(Get-PDMsys2Packages | Sort-Object Name -Unique)
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'packages\crates.windows-x64.tsv'))) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if (Test-PDSelected $parts[0]) { $downloads += [pscustomobject]@{Url = $parts[4]; Sha256 = $parts[3]} }
    }
    Save-PDLockedFiles $downloads
    Write-Host "[playground] Verified offline bundle is ready in $cacheDirectory. No tools or profiles were installed."
    exit 0
}
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or
    [Environment]::OSVersion.Version.Major -lt 10 -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This bootstrap supports x64 Windows 10/11 from 64-bit PowerShell. On macOS/Linux use install.sh.'
}
if ($Interactive) {
    $selectedRoot = Show-PDInstallDirectoryPicker -InitialPath $PlaygroundRoot
    if (-not $selectedRoot) {
        Write-Host '[playground] Installation cancelled.'
        exit 0
    }
    if (-not (Test-PDInstallPath -Path $selectedRoot)) {
        throw 'Choose a playground path containing only letters, digits, dot, underscore, hyphen or slash, with no spaces.'
    }
    $PlaygroundRoot = [IO.Path]::GetFullPath($selectedRoot).TrimEnd('\', '/')
    $installRoot = Join-Path $PlaygroundRoot 'install'
    $binDirectory = Join-Path $PlaygroundRoot 'bin'
    $configDirectory = Join-Path $PlaygroundRoot 'config'
    $cacheDirectory = Join-Path $PlaygroundRoot 'cache'
    $msysRoot = Join-Path $installRoot 'msys2'
}
$installPrivateMsys2 = $false
if ($Interactive -and -not ($Msys2Root -or $Msys2SearchPath -or $UseExistingMsys2)) {
    while ($true) {
        $msys2Choice = Show-PDMSYS2ChoiceMenu -PrivateRoot $msysRoot -AllowInstall:(-not $Msys2ReadOnly)
        if (-not $msys2Choice) {
            Write-Host '[playground] Installation cancelled.'
            exit 0
        }
        if ($msys2Choice -eq 'private') {
            $installPrivateMsys2 = $true
            break
        }
        $searchStart = if ($env:SystemDrive) { $env:SystemDrive + '\' } else { [Environment]::GetFolderPath('UserProfile') }
        $searchPath = Show-PDInstallDirectoryPicker -InitialPath $searchStart -SearchForMsys2
        if (-not $searchPath) { continue }
        $searchResult = Find-Msys2UnderPath -Path $searchPath
        if ($searchResult) {
            $Msys2Root = $searchResult
            break
        }
        Write-Host "[playground] No MSYS2 installation was found under $searchPath. Choose another folder or use a private installation."
    }
}
$msys2 = Select-Msys2Root -DefaultRoot $msysRoot -UsePrivateRoot:$installPrivateMsys2
$msysRoot = $msys2.Root
if ($Msys2ReadOnly -and -not $msys2.PreserveInstalled) {
    throw '-Msys2ReadOnly requires an existing MSYS2 installation.'
}
if ($msysRoot -match '\s') { throw 'MSYS2 must be installed in a path without whitespace.' }
if ($msys2.PreserveInstalled) {
    $normalizedRoot = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\', '/')
    if ($normalizedRoot.Equals($msysRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedRoot.StartsWith($msysRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PlaygroundRoot must be outside the existing MSYS2 installation.'
    }
}
if ($Interactive -and $msys2.PreserveInstalled -and -not $Msys2ReadOnly -and -not $OnlyCodex) {
    $answer = Read-Host 'Use existing MSYS2 packages as-is and skip unavailable tools? [Y/n]'
    if ($answer -notmatch '^(?i:n|no)$') { $Msys2ReadOnly = $true }
}
if ($Interactive -and -not $OnlyCodex) {
    $selection = Show-PDToolSelectionMenu -PlaygroundRoot $PlaygroundRoot -MsysRoot $msysRoot -Msys2ReadOnly $Msys2ReadOnly
    if ($null -eq $selection) {
        Write-Host '[playground] Installation cancelled.'
        exit 0
    }
    $selectedTools = @(Resolve-PDSelectedTools -SelectedTools $selection)
    if ($selectedTools.Count -eq 0) {
        Write-Host '[playground] No tools selected; nothing was installed.'
        exit 0
    }
} elseif ($Interactive) {
    $selectedTools = @('codex')
}
foreach ($directory in @($installRoot, $binDirectory, $configDirectory, $cacheDirectory, (Join-Path $PlaygroundRoot 'tmp'))) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
Copy-PDManager
[IO.Directory]::CreateDirectory((Join-Path $configDirectory 'path')) | Out-Null
$msysConfigRoot = if ($msysRoot.StartsWith($PlaygroundRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $msysRoot.Substring($PlaygroundRoot.TrimEnd('\').Length + 1).Replace('\', '/')
} else { $msysRoot }
[IO.File]::WriteAllText((Join-Path $configDirectory 'path\msys2-root.txt'), $msysConfigRoot + [Environment]::NewLine)
$environmentNames = @('MSYSTEM', 'CHERE_INVOKING', 'MSYS2_PATH_TYPE', 'PD_MSYS2_READY', 'PD_MSYS2_PACKAGES_READY', 'PD_MSYS2_PRESERVE_INSTALLED', 'PD_MSYS2_READ_ONLY', 'PD_SELECTION_MODE', 'PD_SELECTED_TOOLS', 'PD_WEZTERM_EXE', 'PD_BTOP_EXE', 'PD_COPILOT_EXE', 'PD_CODE_EXE', 'PD_NOTEPAD_EXE', 'PD_PWSH_EXE', 'PD_YAZI_SOURCE', 'PD_RUSTIFIEDGIT_SOURCE', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'PD_USER_HOME', 'BASH_ENV', 'PATH')
$savedEnvironment = @{}
$buildSources = @()
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'inherit'
    $env:PD_MSYS2_READY = '1'
    $env:PD_SELECTION_MODE = if ($Interactive -or $Tools.Count) { 'explicit' } else { 'all' }
    $env:PD_SELECTED_TOOLS = $selectedTools -join ','
    $env:TEMP = Join-Path $PlaygroundRoot 'tmp'
    $env:TMP = $env:TEMP
    Install-Msys2
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    Initialize-Msys2 -PreserveInstalled $msys2.PreserveInstalled -ReadOnly $Msys2ReadOnly
    if ((Test-PDSelected yazi) -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'yazi\bin\yazi.exe'))) {
        $source = Prepare-PDWindowsBuild yazi
        $buildSources += $source
        $env:PD_YAZI_SOURCE = ConvertTo-Msys2Path $source
    }
    if ((Test-PDSelected rustifiedgit) -and -not (Test-Path -LiteralPath (Join-Path $installRoot 'rustifiedgit\bin\rustifiedgit.exe'))) {
        $source = Prepare-PDWindowsBuild rustifiedgit
        $buildSources += $source
        $env:PD_RUSTIFIEDGIT_SOURCE = ConvertTo-Msys2Path $source
    }
    if (Test-PDSelected 'wezterm') {
        $env:PD_WEZTERM_EXE = Install-ZipTool -Repo 'wezterm/wezterm' -Pattern '^WezTerm-windows-.*\.zip$' -Name 'wezterm' -Executable 'wezterm.exe'
    }
    if (Test-PDSelected 'btop') {
        $env:PD_BTOP_EXE = Install-ZipTool -Repo 'aristocratos/btop4win' -Pattern '^btop4win-x64\.zip$' -Name 'btop' -Executable 'btop4win.exe'
        Configure-Btop -Executable $env:PD_BTOP_EXE
    }
    if ((Test-PDSelected 'copilot') -or (Test-PDSelected 'pwsh') -or
        (Test-PDSelected 'notepadpp') -or (Test-PDSelected 'vscode') -or
        (Test-PDSelected 'wezterm')) {
        . (Join-Path $PSScriptRoot 'lib\portable.ps1')
        Install-PortableWindowsTools
    }
    if (Test-PDSelected 'codex') { Install-Codex }
    $unixRoot = ConvertTo-Msys2Path -Path $PlaygroundRoot
    $unixMsysRoot = ConvertTo-Msys2Path -Path $msysRoot
    $unixScript = ConvertTo-Msys2Path -Path (Join-Path $PSScriptRoot 'install.sh')
    $arguments = @('--noprofile', '--norc')
    $arguments += @($unixScript, '--root', $unixRoot, '--rustifiedgit-ref', $RustifiedGitRef, '--msys2-root', $unixMsysRoot)
    if ($OnlyCodex) { $arguments += '--only-codex' }
    if ($Msys2ReadOnly) { $arguments += '--msys2-read-only' }
    if ($NoActivate) { $arguments += '--no-activate' } else { $arguments += '--activate' }
    Invoke-Checked -Program $bash -Arguments $arguments
    if (Test-PDSelected 'wezterm') { Update-WezTermMsys2Config }
    Write-WindowsLaunchers
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    foreach ($source in $buildSources) { Remove-Item -LiteralPath $source -Recurse -Force }
}
if (-not $NoActivate) { Register-WindowsPath }
if ($NoActivate) {
    Write-Host ('[playground] Ready. Load extra tools in PowerShell with: . "' + $configDirectory + '\shell\env-extra.ps1"')
} else {
    Write-Host "[playground] Ready. Restart existing terminals/apps to inherit $binDirectory."
}
