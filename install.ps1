#requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $OnlyCodex,
    [switch] $NoActivate,
    [ValidatePattern('^[A-Za-z]:[\\/][A-Za-z0-9_\\/-]+$')]
    [string] $PlaygroundRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'playground'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string] $RustifiedGitRef = '7a2be2ebfa45cfc5be78e788a820ee145953f36b'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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
        $releases = @(Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=30")
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
        if (-not (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\pacman.exe'))) {
            throw "$msysRoot does not contain a valid MSYS2 installation."
        }
        return
    }
    $release = Get-GitHubRelease -Repo 'msys2/msys2-installer' -StableMsys2
    $asset = $release.assets | Where-Object { $_.name -match '^msys2-x86_64-.*\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'No stable x64 MSYS2 installer was found.' }
    $installer = Save-Asset -Asset $asset -Release $release
    $process = Start-Process -FilePath $installer -ArgumentList @(
        'in', '--confirm-command', '--accept-messages', '--root', $msysRoot.Replace('\', '/')
    ) -PassThru -Wait
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bashPath)) {
        throw "MSYS2 did not install successfully under $msysRoot."
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
    try { Invoke-Checked -Program $Executable -Arguments @('--version') }
    catch { throw 'btop4win requires the Microsoft Visual C++ x64 runtime already installed on Windows.' }
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
            ('set "PATH=' + $binDirectory + ';' + $msysRoot + '\ucrt64\bin;' + $msysRoot + '\usr\bin;%PATH%"'),
            ('set "XDG_CONFIG_HOME=' + $configDirectory + '"')
        )
        $extra = ''
        switch ($name) {
            'codex' { $lines += 'set "CODEX_HOME=' + $configDirectory + '\codex"' }
            'yazi' {
                $lines += 'set "YAZI_CONFIG_HOME=' + $configDirectory + '\yazi"'
                $lines += 'set "YAZI_FILE_ONE=' + $msysRoot + '\usr\bin\file.exe"'
            }
            'ya' { $lines += 'set "YAZI_CONFIG_HOME=' + $configDirectory + '\yazi"' }
            'bash' {
                $lines += 'set "BASH_ENV=' + $configDirectory + '\bash\bashrc"'
                $extra = '--rcfile "' + $configDirectory + '\bash\bashrc" '
            }
            'tmux' { $extra = '-f "' + $configDirectory + '\tmux\tmux.conf" ' }
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
        Write-Host "[playground] Install native MSYS2 in $msysRoot."
        Write-Host '[playground] Install Bash, tmux, Yazi, git, Rust and fzf inside MSYS2.'
        Write-Host '[playground] Download portable WezTerm and btop4win under install/.'
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
foreach ($directory in @($installRoot, $binDirectory, $configDirectory, $cacheDirectory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
Install-Msys2
$environmentNames = @('MSYSTEM', 'CHERE_INVOKING', 'MSYS2_PATH_TYPE', 'PD_MSYS2_READY', 'PD_WEZTERM_EXE', 'PD_BTOP_EXE', 'PD_REUSE_CODEX')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'inherit'
    $env:PD_MSYS2_READY = '1'
    $reuseCodex = $NoActivate -and $null -ne (Get-Command codex -CommandType Application -ErrorAction SilentlyContinue)
    $env:PD_REUSE_CODEX = if ($reuseCodex) { '1' } else { '0' }
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    $cygpath = Join-Path $msysRoot 'usr\bin\cygpath.exe'
    Invoke-Checked -Program $bash -Arguments @('--login', '-c', 'true')
    if (-not $OnlyCodex) {
        & $bash --login -c 'pacman --noconfirm -Syu'
        Invoke-Checked -Program $bash -Arguments @('--login', '-c', 'pacman --noconfirm -Syu')
        $env:PD_WEZTERM_EXE = Install-ZipTool -Repo 'wezterm/wezterm' -Pattern '^WezTerm-windows-.*\.zip$' -Name 'wezterm' -Executable 'wezterm.exe'
        $env:PD_BTOP_EXE = Install-ZipTool -Repo 'aristocratos/btop4win' -Pattern '^btop4win-x64\.zip$' -Name 'btop' -Executable 'btop4win.exe'
        Configure-Btop -Executable $env:PD_BTOP_EXE
    }
    if ($reuseCodex) {
        Write-Host '[playground] Keeping the existing Codex command in your terminal setup.'
    } else {
        Install-Codex
    }
    $unixRoot = & $cygpath -u $PlaygroundRoot
    if ($LASTEXITCODE -ne 0) { throw 'Could not translate the playground root.' }
    $unixScript = & $cygpath -u (Join-Path $PSScriptRoot 'install.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Could not translate the installer path.' }
    $arguments = @('--login', $unixScript.Trim(), '--root', $unixRoot.Trim(), '--rustifiedgit-ref', $RustifiedGitRef)
    if ($OnlyCodex) { $arguments += '--only-codex' }
    if ($NoActivate) { $arguments += '--no-activate' }
    Invoke-Checked -Program $bash -Arguments $arguments
    Write-WindowsLaunchers
    if (-not $NoActivate) { Register-WindowsPath }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
if ($NoActivate) {
    Write-Host ('[playground] Ready. Load extra tools in PowerShell with: . "' + $configDirectory + '\shell\env-extra.ps1"')
} else {
    Write-Host "[playground] Ready. Restart existing terminals/apps to inherit $binDirectory."
}
