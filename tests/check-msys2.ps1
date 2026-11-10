#requires -Version 5.1
# Offline fixtures use an isolated MSYS runtime, never an existing installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$hostBash = (Get-Command bash.exe -ErrorAction Stop).Source
$runtimeBin = & $hostBash --noprofile --norc -c '/usr/bin/cygpath.exe -w /usr/bin'
if ($LASTEXITCODE -ne 0) { throw 'Could not locate the fixture Bash runtime.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-msys2-' + [Guid]::NewGuid().ToString('N'))
$msysRoot = Join-Path $root 'msys64'
$PlaygroundRoot = Join-Path $root 'playground'
$helper = Join-Path $repository 'lib\msys2.sh'
$OnlyCodex = $false
$names = @('PD_MSYS2_PRESERVE_INSTALLED', 'PATH', 'BASH_ENV', 'HOME', 'PD_USER_HOME', 'TMPDIR',
    'PD_MSYS_FIXTURE_LOG', 'PD_MSYS_FIXTURE_PACKAGES', 'PD_MSYS_FIXTURE_QUERY_FAIL', 'PD_MSYS_FIXTURE_CHANGE_EXISTING')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Get-Msys2Snapshot {
    return (@(Get-ChildItem -LiteralPath $msysRoot -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $digest = if ($_.PSIsContainer) { 'directory' } else { (Get-FileHash -LiteralPath $_.FullName).Hash }
        $_.FullName + ':' + $digest
    }) -join "`n")
}
try {
    [IO.Directory]::CreateDirectory((Join-Path $msysRoot 'usr\bin')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $msysRoot 'ucrt64\bin')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $msysRoot 'tmp')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $PlaygroundRoot 'tmp')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $PlaygroundRoot 'bin')) | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $runtimeBin -Filter 'msys-*.dll' -File) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $msysRoot 'usr\bin')
    }
    foreach ($name in @('bash', 'sh', 'cygpath', 'mkdir', 'sed', 'cat', 'uname', 'mktemp', 'rm', 'false', 'awk', 'chmod', 'dirname', 'mv', 'env', 'cp')) {
        Copy-Item -LiteralPath (Join-Path $runtimeBin "$name.exe") -Destination (Join-Path $msysRoot 'usr\bin')
    }
    $testBash = Join-Path $msysRoot 'usr\bin\bash.exe'
    # Use the runtime mount's spelling so cygpath maps the fixture root to /.
    $msysRoot = (& (Join-Path $msysRoot 'usr\bin\cygpath.exe') -w /).TrimEnd('\', '/')
    $driver = Join-Path $root 'fixture.exe'
    Add-Type -OutputAssembly $driver -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public class Msys2Fixture {
    public static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        File.AppendAllText(Environment.GetEnvironmentVariable("PD_MSYS_FIXTURE_LOG"),
            name + " " + String.Join(" ", args) + "\n");
        if (name == "pacman" && args.Length == 1 && args[0] == "-Qq") {
            if (Environment.GetEnvironmentVariable("PD_MSYS_FIXTURE_QUERY_FAIL") == "1") {
                Console.Error.WriteLine("fixture database failure");
                return 23;
            }
            Console.WriteLine(Environment.GetEnvironmentVariable("PD_MSYS_FIXTURE_PACKAGES"));
            return 0;
        }
        if (name == "pacman" && args.Length > 0 && args[0] == "-S") {
            if (Environment.GetEnvironmentVariable("PD_MSYS2_PRESERVE_INSTALLED") == "1") {
                int hookIndex = Array.LastIndexOf(args, "--hookdir");
                if (hookIndex < 0 || hookIndex + 1 >= args.Length) return 91;
                string hook = File.ReadAllText(Path.Combine(args[hookIndex + 1], "00-terminal-setup-preserve-installed.hook"));
                foreach (string required in new[] { "Operation = Upgrade", "Operation = Remove", "Type = Package",
                    "Target = *", "When = PreTransaction", "Exec = /usr/bin/false", "AbortOnFail" }) {
                    if (!hook.Contains(required)) return 92;
                }
                if (Environment.GetEnvironmentVariable("PD_MSYS_FIXTURE_CHANGE_EXISTING") == "1") {
                    Console.Error.WriteLine("fixture: dependency change rejected before transaction");
                    return 23;
                }
            }
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "installed"), String.Join(" ", args));
            return 0;
        }
        if (name == "tmux" || name == "yazi") {
            Console.WriteLine("PATH=" + Environment.GetEnvironmentVariable("PATH"));
            Console.WriteLine("YAZI_FILE_ONE=" + Environment.GetEnvironmentVariable("YAZI_FILE_ONE"));
            return 0;
        }
        if (name == "cargo" || name == "rustc" || name == "codex") {
            Console.WriteLine(name + " fixture");
            return 0;
        }
        return name == "bash" ? 0 : 99;
    }
}
'@
    foreach ($name in @('pacman', 'tmux', 'git', 'file')) {
        Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot "usr\bin\$name.exe")
    }
    foreach ($name in @('cargo', 'rustc', 'fzf')) {
        Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot "ucrt64\bin\$name.exe")
    }
    foreach ($relative in @('rustifiedgit\bin\rustifiedgit.exe', 'yazi\bin\yazi.exe', 'yazi\bin\ya.exe', 'codex\bin\codex.exe',
        'wezterm\v1\wezterm.exe', 'btop\v1\btop.exe', 'copilot\v1\copilot.exe', 'powershell\v1\pwsh.exe',
        'vscode\v1\Code.exe', 'notepad++\v1\notepad++.exe')) {
        $path = Join-Path (Join-Path $PlaygroundRoot 'install') $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        Copy-Item -LiteralPath $driver -Destination $path
    }
    $env:PD_MSYS_FIXTURE_LOG = Join-Path $root 'calls'
    $packages = @('bash', 'tmux', 'git', 'file') + @(
        'rust', 'fzf', 'ffmpeg', '7zip', 'jq', 'poppler', 'fd', 'ripgrep', 'zoxide', 'resvg', 'imagemagick'
    ) | ForEach-Object {
        if ($_ -in @('bash', 'tmux', 'git', 'file')) { $_ } else { 'mingw-w64-ucrt-x86_64-' + $_ }
    }
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $env:PD_MSYS_FIXTURE_QUERY_FAIL = '0'
    $env:PD_MSYS_FIXTURE_CHANGE_EXISTING = '0'
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Test-Msys2Installation', 'Find-Msys2UnderPath', 'Select-Msys2Root', 'ConvertTo-Msys2Path', 'Initialize-Msys2')) {
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
    }
    function Find-SystemMsys2 { return $msysRoot }
    function Invoke-Checked {
        param([string] $Program, [string[]] $Arguments)
        $ErrorActionPreference = 'Continue'
        if ($env:PD_MSYS2_PRESERVE_INSTALLED -eq '1') {
            Assert ($Arguments[0] -eq '--noprofile' -and $Arguments[1] -eq '--norc') 'Existing MSYS2 setup loaded shell startup files.'
        }
        $output = & $Program @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    }
    $before = Get-Msys2Snapshot
    foreach ($mode in @('explicit', 'detected', 'scoped-search')) {
        $Msys2Root = if ($mode -eq 'explicit') { $msysRoot } else { $null }
        $UseExistingMsys2 = $mode -eq 'detected'
        $Msys2SearchPath = if ($mode -eq 'scoped-search') { $root } else { $null }
        $selection = Select-Msys2Root -DefaultRoot (Join-Path $PlaygroundRoot 'install\msys2')
        Assert $selection.PreserveInstalled 'Reused MSYS2 was not protected.'
        Assert ($selection.Root.Equals($msysRoot, [StringComparison]::OrdinalIgnoreCase)) 'Setup selected the wrong MSYS2 installation.'
        $env:BASH_ENV = Join-Path $msysRoot 'startup-must-not-run'
        $env:HOME = Join-Path $msysRoot 'home'
        Initialize-Msys2 -PreserveInstalled $selection.PreserveInstalled
        Assert (-not $env:BASH_ENV) 'Existing MSYS2 setup inherited BASH_ENV.'
        $unixPlayground = ConvertTo-Msys2Path -Path $PlaygroundRoot
        Assert ($env:HOME.StartsWith($unixPlayground + '/')) 'Build home is not isolated from reused MSYS2.'
        $mappedRoot = & (Join-Path $msysRoot 'usr\bin\cygpath.exe') -u $msysRoot
        $nativeRoot = & (Join-Path $msysRoot 'usr\bin\cygpath.exe') -w /
        Assert ($mappedRoot -ceq '/') "Fixture did not reproduce the MSYS2 root mount: $mappedRoot (native root: $nativeRoot)."
        Assert ((ConvertTo-Msys2Path -Path $msysRoot).StartsWith('/proc/cygdrive/')) 'Generated paths depend on the current MSYS root.'
        Assert ((Get-Msys2Snapshot) -ceq $before) 'Setup changed MSYS2 with all prerequisites already installed.'
    }
    $Msys2SearchPath = $null
    $calls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert ($calls.Count -eq 3 -and @($calls | Where-Object { $_ -cne 'pacman -Qq' }).Count -eq 0) 'Setup modified existing packages.'

    foreach ($failure in @('dependency-change', 'database')) {
        $env:PD_MSYS_FIXTURE_PACKAGES = ($packages | Where-Object { $_ -ne 'tmux' }) -join "`n"
        $env:PD_MSYS_FIXTURE_QUERY_FAIL = if ($failure -eq 'database') { '1' } else { '0' }
        $env:PD_MSYS_FIXTURE_CHANGE_EXISTING = '1'
        $message = ''
        try { Initialize-Msys2 -PreserveInstalled $true } catch { $message = $_.Exception.Message }
        $expected = if ($failure -eq 'database') { 'Could not read the existing MSYS2 package database' } else { 'without changing existing packages' }
        Assert ($message.Contains($expected)) "Preflight did not report $failure prerequisites: $message"
        Assert ((Get-Msys2Snapshot) -ceq $before) 'Failed preflight changed MSYS2.'
    }
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $env:PD_MSYS_FIXTURE_QUERY_FAIL = '0'
    $env:PD_MSYS_FIXTURE_CHANGE_EXISTING = '0'
    $env:PD_MSYS_FIXTURE_PACKAGES = ($packages | Where-Object { $_ -ne 'tmux' }) -join "`n"
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $true
    $installedMarker = Join-Path $msysRoot 'usr\bin\installed'
    Assert ([IO.File]::ReadAllText($installedMarker).EndsWith(' tmux')) 'Setup did not install only the missing package.'
    Remove-Item -LiteralPath $installedMarker
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Installing a missing package changed existing files.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $PlaygroundRoot 'tmp') -Filter 'msys2-hooks.*').Count -eq 0) 'Temporary pacman guard was not cleaned up.'
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $OnlyCodex = $true
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $true
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG) -eq '') 'Codex-only setup queried or modified MSYS2 packages.'
    $OnlyCodex = $false

    $shellCheck = Join-Path $root 'packages.sh'
    [IO.File]::WriteAllText($shellCheck, @'
set -euo pipefail
. "$1"
PD_MSYS2_ROOT="$2"
PD_MSYS2_PRESERVE_INSTALLED="$3"
pd_install_msys2_packages
'@)
    & $hostBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 1
    Assert ($LASTEXITCODE -eq 0) 'Existing Bash package setup failed.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Bash package setup changed reused MSYS2.'
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG).Trim() -ceq 'pacman -Qq') 'Bash package setup ran a modifying command.'

    $rootCheck = Join-Path $root 'root-paths.sh'
    [IO.File]::WriteAllText($rootCheck, @'
set -euo pipefail
PD_ROOT="$2"
PD_INSTALL="$PD_ROOT/install"
PD_TEMP="$PD_ROOT/tmp"
PD_REF=main
PD_OS=windows
PD_MSYS2_ROOT="$3"
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
. "$1/lib/environment.sh"
. "$1/lib/rustifiedgit.sh"
. "$1/lib/yazi.sh"
pd_write_environment
pd_install_rust
"$PD_CARGO" --version
"$PD_RUSTC" --version
pd_write_launcher tmux "${PD_MSYS2_ROOT%/}/usr/bin/tmux.exe"
pd_write_launcher yazi "$PD_INSTALL/yazi/bin/yazi.exe"
install_rustifiedgit
install_portable_yazi_windows
"$PD_ROOT/bin/tmux" --version
"$PD_ROOT/bin/yazi" --version
export PD_WEZTERM_EXE="$(cygpath -w "$PD_INSTALL/wezterm/v1/wezterm.exe")"
export PD_BTOP_EXE="$(cygpath -w "$PD_INSTALL/btop/v1/btop.exe")"
export PD_COPILOT_EXE="$(cygpath -w "$PD_INSTALL/copilot/v1/copilot.exe")"
export PD_PWSH_EXE="$(cygpath -w "$PD_INSTALL/powershell/v1/pwsh.exe")"
export PD_CODE_EXE="$(cygpath -w "$PD_INSTALL/vscode/v1/Code.exe")"
export PD_NOTEPAD_EXE="$(cygpath -w "$PD_INSTALL/notepad++/v1/notepad++.exe")"
PD_MSYS2_READY=1 "$BASH" "$1/install.sh" --root "$PD_ROOT" --msys2-root "$PD_MSYS2_ROOT"
PD_MSYS2_READY=1 "$BASH" "$1/install.sh" --root "$PD_ROOT" --msys2-root "$PD_MSYS2_ROOT" --only-codex
'@)
    $output = & $testBash --noprofile --norc $rootCheck.Replace('\', '/') $repository.Replace('\', '/') $unixPlayground / 2>&1
    Assert ($LASTEXITCODE -eq 0) ("Root-mounted toolchain or launchers failed: " + ($output -join "`n"))
    $text = ($output -join "`n").Replace('\', '/')
    Assert ($text.Contains($msysRoot.Replace('\', '/') + '/ucrt64/bin')) 'Launcher PATH did not resolve the root-mounted UCRT64 tools.'
    Assert ($text.Contains('YAZI_FILE_ONE=' + $msysRoot.Replace('\', '/') + '/usr/bin/file.exe')) 'Yazi launcher did not resolve its root-mounted file helper.'
    $manifest = [IO.File]::ReadAllText((Join-Path $PlaygroundRoot 'state\windows-commands.tsv'))
    Assert ($manifest.Contains("tmux`t") -and $manifest.Contains("codex`t")) 'Codex-only setup lost the active versions of other tools.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Root-mounted launchers changed existing MSYS2 files.'
    $portableRoot = ConvertTo-Msys2Path -Path $msysRoot
    $output = & $testBash --noprofile --norc $rootCheck.Replace('\', '/') $repository.Replace('\', '/') $unixPlayground $portableRoot 2>&1
    Assert ($LASTEXITCODE -eq 0) ("Portable MSYS2 root paths failed: " + ($output -join "`n"))
    $output = & $hostBash --noprofile --norc (Join-Path $PlaygroundRoot 'bin\tmux').Replace('\', '/') --version 2>&1
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n").Replace('\', '/').Contains($msysRoot.Replace('\', '/') + '/ucrt64/bin')) 'Launcher selected the host Bash installation instead of the configured MSYS2.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Cross-runtime launcher changed existing MSYS2 files.'

    $nestedRoot = Join-Path $msysRoot 'must-not-create'
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoProfile -File (Join-Path $repository 'install.ps1') `
        -Msys2Root $msysRoot -PlaygroundRoot $nestedRoot 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -ne 0 -and ($output -join "`n").Contains('outside the existing MSYS2')) 'Setup allowed a playground inside existing MSYS2.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Rejected nested playground changed MSYS2.'

    function Find-SystemMsys2 { return $null }
    $Msys2Root = $null
    $UseExistingMsys2 = $false
    $selection = Select-Msys2Root -DefaultRoot $msysRoot
    Assert $selection.PreserveInstalled 'Previously managed MSYS2 was not protected on rerun.'
    $selection = Select-Msys2Root -DefaultRoot (Join-Path $root 'fresh-msys2')
    Assert (-not $selection.PreserveInstalled) 'Fresh MSYS2 installation unexpectedly disabled initialization.'
    Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot 'usr\bin\bash.exe') -Force
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $selection.PreserveInstalled
    $calls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert (@($calls | Where-Object { $_ -eq 'bash --login -c pacman --noconfirm -Syu' }).Count -eq 2) 'Managed MSYS2 no longer performs both system upgrade passes.'
    & $hostBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 0
    Assert ($LASTEXITCODE -eq 0) 'Managed Bash package installation failed.'
    Assert (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\installed')) 'Managed MSYS2 did not install required packages.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host 'Root-mounted MSYS2, missing-only packages, dependency guards and preserved compiled tools passed.'
