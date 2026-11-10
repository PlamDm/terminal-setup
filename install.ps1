#requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $OnlyCodex,
    [switch] $NoActivate,
    [switch] $Activate,
    [switch] $UseExistingMsys2,
    [ValidatePattern('^[A-Za-z]:[\\/][A-Za-z0-9_\\/-]+$')]
    [string] $Msys2Root,
    [ValidatePattern('^[A-Za-z]:[\\/][A-Za-z0-9_\\/-]+$')]
    [string] $PlaygroundRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'playground'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string] $RustifiedGitRef = '7a2be2ebfa45cfc5be78e788a820ee145953f36b'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Activate -and $NoActivate) { throw 'Choose either -Activate or -NoActivate.' }
$NoActivate = -not $Activate
$installRoot = Join-Path $PlaygroundRoot 'install'
$binDirectory = Join-Path $PlaygroundRoot 'bin'
$configDirectory = Join-Path $PlaygroundRoot 'config'
$cacheDirectory = Join-Path $PlaygroundRoot 'cache'
$msysRoot = Join-Path $installRoot 'msys2'
$headers = @{ 'User-Agent' = 'terminal-setup'; 'Accept' = 'application/vnd.github+json' }

function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}
function Get-GitHubRelease {
    param([string] $Repo, [switch] $StableMsys2)
    if ($StableMsys2) {
        # Assign directly: wrapping Invoke-RestMethod in @() can nest its JSON
        # array in Windows PowerShell, making Where-Object see one array item.
        $releases = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=30"
        $release = $releases | Where-Object {
            -not $_.prerelease -and -not $_.draft -and $_.tag_name -notmatch 'nightly'
        } | Select-Object -First 1
    } else {
        $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest"
    }
    if (-not $release) { throw "No release was found for $Repo." }
    return $release
}
function Save-Asset {
    param([object] $Asset, [object] $Release)
    $destination = Join-Path $cacheDirectory $Asset.name
    $expected = $null
    if ($Asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
        $expected = $Matches[1]
    } else {
        $checksumAsset = $Release.assets | Where-Object { $_.name -eq ($Asset.name + '.sha256') } | Select-Object -First 1
        if ($checksumAsset) {
            $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri $checksumAsset.browser_download_url).Content
            if ($checksumText -match '\b([a-fA-F0-9]{64})\b') { $expected = $Matches[1] }
        }
    }
    if (-not $expected) { throw "No published SHA-256 was found for $($Asset.name)." }
    if ((Test-Path -LiteralPath $destination) -and
        (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash -eq $expected) {
        return $destination
    }
    Invoke-WebRequest -UseBasicParsing -Uri $Asset.browser_download_url -OutFile $destination
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash -ne $expected) {
        throw "SHA-256 verification failed for $($Asset.name)."
    }
    return $destination
}
function Install-ZipTool {
    param([string] $Repo, [string] $Pattern, [string] $Name, [string] $Executable)
    $release = Get-GitHubRelease -Repo $Repo
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No suitable $Name archive exists in $Repo." }
    $destination = Join-Path (Join-Path $installRoot $Name) $release.tag_name
    $found = @()
    if (Test-Path -LiteralPath $destination) {
        $found = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter $Executable)
    }
    if ($found.Count -eq 0) {
        $archive = Save-Asset -Asset $asset -Release $release
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
        $found = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter $Executable)
    }
    if ($found.Count -ne 1) { throw "Expected one $Executable under $destination." }
    return $found[0].FullName
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
            foreach ($match in Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Directory `
                -Filter 'msys64' -Recurse -Force -ErrorAction SilentlyContinue) {
                if (Test-Msys2Installation -Path $match.FullName) {
                    return [IO.Path]::GetFullPath($match.FullName).TrimEnd('\', '/')
                }
            }
        }
    }
    return $null
}
function Select-Msys2Root {
    param([string] $DefaultRoot)
    if ($Msys2Root) {
        if (-not (Test-Msys2Installation -Path $Msys2Root)) {
            throw "The requested MSYS2 root does not contain bash, pacman and cygpath: $Msys2Root"
        }
        return [pscustomobject]@{
            Root = [IO.Path]::GetFullPath($Msys2Root).TrimEnd('\', '/')
            ReadOnly = $true
        }
    }
    $canPrompt = $Host.Name -eq 'ConsoleHost' -and $env:CI -notin @('true', '1')
    $detectedRoot = Find-SystemMsys2 -SearchFixedDrives:($UseExistingMsys2 -or $canPrompt)
    if ($UseExistingMsys2) {
        if (-not $detectedRoot) {
            throw 'No existing MSYS2 installation was found on the fixed drives. Run without -UseExistingMsys2 to install a private copy.'
        }
        Write-Host "[playground] Reusing system MSYS2 at $detectedRoot."
        return [pscustomobject]@{ Root = $detectedRoot; ReadOnly = $true }
    }
    if ($detectedRoot -and $canPrompt) {
        $answer = Read-Host "Found MSYS2 at $detectedRoot. Reuse it? [y/N]"
        if ($answer -match '^(?i:y|yes)$') {
            Write-Host "[playground] Reusing system MSYS2 at $detectedRoot."
            return [pscustomobject]@{ Root = $detectedRoot; ReadOnly = $true }
        }
        Write-Host "[playground] Installing a separate MSYS2 under $DefaultRoot."
    }
    return [pscustomobject]@{ Root = $DefaultRoot; ReadOnly = $false }
}
function ConvertTo-Msys2Path {
    param([string] $Path)
    $converted = & (Join-Path $msysRoot 'usr\bin\cygpath.exe') -u $Path
    if ($LASTEXITCODE -ne 0) { throw "Could not translate path for MSYS2: $Path" }
    return $converted.Trim()
}
function Initialize-Msys2 {
    param([bool] $ReadOnly)
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    $env:PD_MSYS2_READ_ONLY = if ($ReadOnly) { '1' } else { '0' }
    if ($ReadOnly) {
        $env:PATH = "$msysRoot\ucrt64\bin;$msysRoot\usr\bin;$env:PATH"
        $env:BASH_ENV = $null
        $homeDirectory = Join-Path $PlaygroundRoot 'state\msys2-home'
        [IO.Directory]::CreateDirectory($homeDirectory) | Out-Null
        $env:HOME = ConvertTo-Msys2Path -Path $homeDirectory
        $env:PD_USER_HOME = ConvertTo-Msys2Path -Path ([Environment]::GetFolderPath('UserProfile'))
        $env:TMPDIR = ConvertTo-Msys2Path -Path (Join-Path $PlaygroundRoot 'tmp')
        if (-not $OnlyCodex) {
            Write-Host "[playground] Existing MSYS2 is read-only; checking prerequisites at $msysRoot."
            $checkScript = ConvertTo-Msys2Path -Path (Join-Path $PSScriptRoot 'lib\msys2.sh')
            $unixMsysRoot = ConvertTo-Msys2Path -Path $msysRoot
            Invoke-Checked -Program $bash -Arguments @('--noprofile', '--norc', $checkScript, $unixMsysRoot)
        }
    } else {
        Invoke-Checked -Program $bash -Arguments @('--login', '-c', 'true')
        if (-not $OnlyCodex) {
            & $bash --login -c 'pacman --noconfirm -Syu'
            Invoke-Checked -Program $bash -Arguments @('--login', '-c', 'pacman --noconfirm -Syu')
        }
    }
}
function Install-Codex {
    $codexHome = Join-Path $configDirectory 'codex'
    $codexBin = Join-Path $installRoot 'codex\bin'
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    $packageLink = Join-Path $codexHome 'packages'
    $packagePayload = Join-Path $installRoot 'codex\packages'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $packagePayload)) | Out-Null
    if (Test-Path -LiteralPath $packageLink) {
        $item = Get-Item -LiteralPath $packageLink -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ((@($item.Target)[0]).TrimEnd('\') -ine $packagePayload.TrimEnd('\')) {
                throw 'Codex package junction points outside the playground installation.'
            }
        } else {
            if (Test-Path -LiteralPath $packagePayload) { throw 'Two Codex package directories exist; refusing to merge them.' }
            Move-Item -LiteralPath $packageLink -Destination $packagePayload
            New-Item -ItemType Junction -Path $packageLink -Target $packagePayload | Out-Null
        }
    } else {
        [IO.Directory]::CreateDirectory($packagePayload) | Out-Null
        New-Item -ItemType Junction -Path $packageLink -Target $packagePayload | Out-Null
    }
    $temporary = Join-Path $cacheDirectory 'codex-install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://chatgpt.com/codex/install.ps1' -OutFile $temporary
    $names = @('CODEX_HOME', 'CODEX_INSTALL_DIR', 'CODEX_NON_INTERACTIVE')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $previousUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    try {
        $env:CODEX_HOME = $codexHome
        $env:CODEX_INSTALL_DIR = $codexBin
        $env:CODEX_NON_INTERACTIVE = '1'
        Invoke-Checked -Program 'powershell.exe' -Arguments @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $temporary
        )
    } finally {
        # The upstream installer registers its own bin even for a custom root.
        if ($NoActivate) { [Environment]::SetEnvironmentVariable('Path', $previousUserPath, 'User') }
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
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
    if (-not (Test-Path -LiteralPath $central)) {
        if (Test-Path -LiteralPath $bundled) {
            Copy-Item -LiteralPath $bundled -Destination $central
        } else {
            [IO.File]::WriteAllText($central, '')
        }
    }
    # btop4win requires a co-located config; a hard link keeps it editable in config/.
    if (Test-Path -LiteralPath $bundled) { Remove-Item -LiteralPath $bundled -Force }
    New-Item -ItemType HardLink -Path $bundled -Target $central | Out-Null
    # The portable release links its C++ runtime statically.
    Invoke-Checked -Program $Executable -Arguments @('--version')
}
function Write-WindowsLaunchers {
    $manifest = Join-Path $PlaygroundRoot 'state\windows-commands.tsv'
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split([char]9, 2)
        $name = $parts[0]
        $target = $parts[1]
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
            ('set "GIT_CONFIG_GLOBAL=' + $configDirectory + '\git\config"')
        )
        $extra = ''
        switch ($name) {
            'codex' { $lines += 'set "CODEX_HOME=' + $configDirectory + '\codex"' }
            'copilot' {
                $lines += 'set "COPILOT_HOME=' + $configDirectory + '\copilot"'
                $lines += 'set "COPILOT_CACHE_HOME=' + $cacheDirectory + '\copilot"'
                $lines += 'set "COPILOT_AUTO_UPDATE=false"'
                $lines += 'set "PATH=' + (Split-Path -Parent $env:PD_PWSH_EXE) + ';%PATH%"'
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
                $lines += 'set "YAZI_FILE_ONE=' + $msysRoot + '\usr\bin\file.exe"'
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
if ($DryRun) {
    Write-Host "[playground] Preview only; root: $PlaygroundRoot"
    if (-not $OnlyCodex) {
        Write-Host "[playground] Install MSYS2 in $msysRoot by default; use -UseExistingMsys2 or -Msys2Root to reuse an existing installation."
        Write-Host '[playground] Reused MSYS2 is read-only: check required packages without upgrades or installs; stop if prerequisites are missing.'
        Write-Host '[playground] Install Bash, tmux, git, Rust and fzf only in managed MSYS2; build Yazi with portable cache/state overrides.'
        Write-Host '[playground] Download portable WezTerm and btop4win under install/.'
        Write-Host '[playground] Add Yazi preview/search helpers, portable PowerShell 7, GitHub Copilot CLI, VS Code, Notepad++ and a private Nerd Font.'
        Write-Host "[playground] Build PlamDm/RustifiedGit at $RustifiedGitRef."
    }
    Write-Host '[playground] Install native Codex CLI under install/codex, with config/codex state.'
    Write-Host "[playground] Create CMD and Bash launchers in $binDirectory."
    if ($NoActivate) {
        Write-Host '[playground] Leave profiles and persistent PATH unchanged; generate manual activation files.'
    } else {
        Write-Host '[playground] Persist the Windows user PATH and broadcast the environment change.'
    }
    exit 0
}
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'This bootstrap requires 64-bit Windows. On macOS/Linux use install.sh.'
}
$msys2 = Select-Msys2Root -DefaultRoot $msysRoot
$msysRoot = $msys2.Root
if ($msysRoot -match '\s') { throw 'MSYS2 must be installed in a path without whitespace.' }
if ($msys2.ReadOnly) {
    $normalizedRoot = [IO.Path]::GetFullPath($PlaygroundRoot).TrimEnd('\', '/')
    if ($normalizedRoot.Equals($msysRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedRoot.StartsWith($msysRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PlaygroundRoot must be outside the read-only MSYS2 installation.'
    }
}
foreach ($directory in @($installRoot, $binDirectory, $configDirectory, $cacheDirectory, (Join-Path $PlaygroundRoot 'tmp'))) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
[IO.Directory]::CreateDirectory((Join-Path $configDirectory 'path')) | Out-Null
[IO.File]::WriteAllText((Join-Path $configDirectory 'path\msys2-root.txt'), $msysRoot + [Environment]::NewLine)
Install-Msys2
$environmentNames = @('MSYSTEM', 'CHERE_INVOKING', 'MSYS2_PATH_TYPE', 'PD_MSYS2_READY', 'PD_MSYS2_READ_ONLY', 'PD_WEZTERM_EXE', 'PD_BTOP_EXE', 'PD_COPILOT_EXE', 'PD_CODE_EXE', 'PD_NOTEPAD_EXE', 'PD_PWSH_EXE', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'PD_USER_HOME', 'BASH_ENV', 'PATH')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'inherit'
    $env:PD_MSYS2_READY = '1'
    $env:TEMP = Join-Path $PlaygroundRoot 'tmp'
    $env:TMP = $env:TEMP
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    Initialize-Msys2 -ReadOnly $msys2.ReadOnly
    if (-not $OnlyCodex) {
        $env:PD_WEZTERM_EXE = Install-ZipTool -Repo 'wezterm/wezterm' -Pattern '^WezTerm-windows-.*\.zip$' -Name 'wezterm' -Executable 'wezterm.exe'
        $env:PD_BTOP_EXE = Install-ZipTool -Repo 'aristocratos/btop4win' -Pattern '^btop4win-x64\.zip$' -Name 'btop' -Executable 'btop4win.exe'
        Configure-Btop -Executable $env:PD_BTOP_EXE
        . (Join-Path $PSScriptRoot 'lib\portable.ps1')
        Install-PortableWindowsTools
    }
    Install-Codex
    $unixRoot = ConvertTo-Msys2Path -Path $PlaygroundRoot
    $unixMsysRoot = ConvertTo-Msys2Path -Path $msysRoot
    $unixScript = ConvertTo-Msys2Path -Path (Join-Path $PSScriptRoot 'install.sh')
    $arguments = if ($msys2.ReadOnly) { @('--noprofile', '--norc') } else { @('--login') }
    $arguments += @($unixScript, '--root', $unixRoot, '--rustifiedgit-ref', $RustifiedGitRef, '--msys2-root', $unixMsysRoot)
    if ($OnlyCodex) { $arguments += '--only-codex' }
    if ($NoActivate) { $arguments += '--no-activate' } else { $arguments += '--activate' }
    Invoke-Checked -Program $bash -Arguments $arguments
    Update-WezTermMsys2Config
    Write-WindowsLaunchers
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
if (-not $NoActivate) { Register-WindowsPath }
if ($NoActivate) {
    Write-Host ('[playground] Ready. Load extra tools in PowerShell with: . "' + $configDirectory + '\shell\env-extra.ps1"')
} else {
    Write-Host "[playground] Ready. Restart existing terminals/apps to inherit $binDirectory."
}
