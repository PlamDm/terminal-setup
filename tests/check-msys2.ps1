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
$Msys2ReadOnly = $false
$script:widePackages = $false
. (Join-Path $repository 'lib\packages.ps1')
$names = @('PD_MSYS2_PRESERVE_INSTALLED', 'PD_MSYS2_READ_ONLY', 'PATH', 'BASH_ENV', 'HOME', 'PD_USER_HOME', 'TMPDIR',
    'PD_MSYS2_READY', 'PD_MSYS2_PACKAGES_READY', 'PD_SELECTION_MODE', 'PD_SELECTED_TOOLS', 'PD_WEZTERM_EXE', 'PD_BTOP_EXE', 'PD_COPILOT_EXE', 'PD_CODE_EXE', 'PD_NOTEPAD_EXE',
    'PD_PWSH_EXE', 'PD_OS', 'PD_MSYS_FIXTURE_LOG', 'PD_MSYS_FIXTURE_PACKAGES',
    'PD_MSYS_FIXTURE_QUERY_FAIL', 'PD_MSYS_FIXTURE_CHANGE_EXISTING')
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
    foreach ($name in @('bash', 'sh', 'cygpath', 'mkdir', 'sed', 'cat', 'uname', 'mktemp', 'rm', 'false', 'awk', 'grep', 'chmod', 'dirname', 'basename', 'find', 'sort', 'mv', 'env', 'cp')) {
        Copy-Item -LiteralPath (Join-Path $runtimeBin "$name.exe") -Destination (Join-Path $msysRoot 'usr\bin')
    }
    $testBash = Join-Path $msysRoot 'usr\bin\bash.exe'
    $originalBash = Join-Path $root 'original-bash.exe'
    Copy-Item -LiteralPath $testBash -Destination $originalBash
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
        if (name == "pacman" && Array.IndexOf(args, "-Syu") >= 0) return 0;
        if (name == "pacman" && args.Length > 0 && (args[0] == "-S" || args[0] == "-U")) {
            if (args[0] == "-U" || Environment.GetEnvironmentVariable("PD_MSYS2_PRESERVE_INSTALLED") == "1") {
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
            string targets = Array.IndexOf(args, "-") >= 0 ? Console.In.ReadToEnd() : String.Join(" ", args);
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "installed"), targets);
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
        return name == "bash" || name == "pacman-key" || name == "gpgconf" ? 0 : 99;
    }
}
'@
    foreach ($name in @('pacman', 'pacman-key', 'gpgconf', 'tmux', 'git', 'file')) {
        Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot "usr\bin\$name.exe")
    }
    foreach ($name in @('cargo', 'rustc', 'fzf', 'ffmpeg', 'ffprobe', '7z', 'jq', 'pdftoppm', 'pdftotext',
        'pdfinfo', 'fd', 'rg', 'zoxide', 'resvg', 'magick')) {
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
    function Get-PDMsys2Packages {
        if ($OnlyCodex) { return }
        if ($script:widePackages) {
            foreach ($index in 1..250) {
                $name = 'fixture-long-package-name-' + $index.ToString('0000')
                [pscustomobject]@{Name=$name; Url="https://example.invalid/$name.fixture.pkg.tar.zst"; Sha256=('a' * 64); Signature=''}
            }
            return
        }
        foreach ($name in $packages) {
            $features = switch ($name) {
                bash { @('bash', 'tmux', 'git', 'yazi', 'rustifiedgit', 'fzf') }
                tmux { @('tmux') }
                git { @('git', 'yazi', 'rustifiedgit') }
                mingw-w64-ucrt-x86_64-rust { @('yazi', 'rustifiedgit') }
                mingw-w64-ucrt-x86_64-fzf { @('fzf') }
                default { @('yazi') }
            }
            if ($env:PD_SELECTION_MODE -eq 'explicit' -and
                -not @($features | Where-Object { $_ -in $env:PD_SELECTED_TOOLS.Split(',') }).Count) { continue }
            [pscustomobject]@{Name=$name; Url="https://example.invalid/$name.fixture.pkg.tar.zst"; Sha256=('a' * 64); Signature=''}
        }
    }
    function Save-PDLockedFiles { param([object[]] $Files) }
    function Save-PDLockedFile {
        param([string] $Url, [string] $Sha256)
        $directory = Join-Path $PlaygroundRoot 'cache'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $file = Join-Path $directory ([IO.Path]::GetFileName(([Uri]$Url).AbsolutePath))
        [IO.File]::WriteAllText($file, 'fixture archive')
        return $file
    }
    $env:PD_MSYS_FIXTURE_QUERY_FAIL = '0'
    $env:PD_MSYS_FIXTURE_CHANGE_EXISTING = '0'
    $env:PD_SELECTION_MODE = 'all'
    $env:PD_SELECTED_TOOLS = ''
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
        Assert ($Arguments[0] -eq '--noprofile' -and $Arguments[1] -eq '--norc') 'MSYS2 setup loaded shell startup files.'
        $output = & $Program @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$Program $($Arguments -join ' ') failed with exit code $LASTEXITCODE. $($output -join "`n")"
        }
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

    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $true -ReadOnly $true
    Assert ($env:PD_MSYS2_READ_ONLY -eq '1') 'Read-only MSYS2 mode was not passed to Bash.'
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG) -eq '') 'Read-only MSYS2 setup queried or modified packages.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Read-only MSYS2 setup changed existing files.'

    $env:PD_SELECTION_MODE = 'explicit'
    $env:PD_SELECTED_TOOLS = 'yazi,wezterm'
    $env:PD_MSYS_FIXTURE_PACKAGES = 'bash'
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $true
    $selectedPackages = [IO.File]::ReadAllText((Join-Path $msysRoot 'usr\bin\installed'))
    Assert ($selectedPackages.Contains('git') -and $selectedPackages.Contains('mingw-w64-ucrt-x86_64-rust') -and
        $selectedPackages.Contains('mingw-w64-ucrt-x86_64-ffmpeg')) "Selected Yazi dependencies were not installed: $selectedPackages"
    Assert (-not $selectedPackages.Contains('tmux.pkg.tar') -and
        -not $selectedPackages.Contains('mingw-w64-ucrt-x86_64-fzf')) 'Unselected MSYS2 tools were requested.'
    Remove-Item -LiteralPath (Join-Path $msysRoot 'usr\bin\installed')
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Selected-package preflight changed existing MSYS2 files.'
    $env:PD_SELECTION_MODE = 'all'
    $env:PD_SELECTED_TOOLS = ''
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"

    foreach ($failure in @('dependency-change', 'database')) {
        $env:PD_MSYS_FIXTURE_PACKAGES = ($packages | Where-Object { $_ -ne 'tmux' }) -join "`n"
        $env:PD_MSYS_FIXTURE_QUERY_FAIL = if ($failure -eq 'database') { '1' } else { '0' }
        $env:PD_MSYS_FIXTURE_CHANGE_EXISTING = '1'
        $message = ''
        try { Initialize-Msys2 -PreserveInstalled $true } catch { $message = $_.Exception.Message }
        $expected = if ($failure -eq 'database') { 'private package database' } else { 'dependency change rejected' }
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
    Assert ([IO.File]::ReadAllText($installedMarker).Trim().EndsWith(' tmux.pkg.tar.zst')) 'Setup did not install only the missing package.'
    Remove-Item -LiteralPath $installedMarker
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Installing a missing package changed existing files.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $PlaygroundRoot 'tmp') -Filter 'msys2-hooks.*').Count -eq 0) 'Temporary pacman guard was not cleaned up.'
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $script:widePackages = $true
    Initialize-Msys2 -PreserveInstalled $true
    $wide = [IO.File]::ReadAllText($installedMarker)
    Assert ($wide.Contains('fixture-long-package-name-0250.pkg.tar.zst')) 'Large dependency closure exceeded the Windows command-line limit.'
    Remove-Item -LiteralPath $installedMarker
    $script:widePackages = $false
    $OnlyCodex = $true
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $true
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG) -eq '') 'Codex-only setup queried or modified MSYS2 packages.'
    $OnlyCodex = $false

    $env:PD_MSYS_FIXTURE_LOG = Join-Path $root 'private-calls'
    $env:BASH_ENV = Join-Path $root 'startup-must-not-run'
    $env:HOME = Join-Path $root 'host-home'
    $env:TMPDIR = Join-Path $root 'host-tmp'
    $privateHome = Join-Path $PlaygroundRoot 'state\msys2-home'
    [IO.Directory]::CreateDirectory($privateHome) | Out-Null
    $privateStartupMarker = Join-Path $root 'private-startup-ran'
    $privateMarkerUnix = ConvertTo-Msys2Path -Path $privateStartupMarker
    [IO.File]::WriteAllText((Join-Path $privateHome '.bash_profile'), "echo ran > '$privateMarkerUnix'`n")
    Initialize-Msys2 -PreserveInstalled $false
    Assert (-not $env:BASH_ENV) 'Private MSYS2 setup inherited BASH_ENV.'
    Assert (-not (Test-Path -LiteralPath $privateStartupMarker)) 'Private MSYS2 setup loaded the isolated Bash startup file.'
    $unixPlayground = ConvertTo-Msys2Path -Path $PlaygroundRoot
    Assert ($env:HOME.StartsWith($unixPlayground + '/')) 'Private MSYS2 build home is not isolated under the playground.'
    Assert ($env:TMPDIR.StartsWith($unixPlayground + '/')) 'Private MSYS2 temporary files are not isolated under the playground.'
    Assert ($env:PATH.StartsWith("$msysRoot\ucrt64\bin;$msysRoot\usr\bin;")) 'Private MSYS2 binaries were not prepended to PATH.'
    $privateCalls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert (($privateCalls -join "`n").Contains('pacman-key --init') -and
        ($privateCalls -join "`n").Contains('pacman-key --populate msys2') -and
        -not ($privateCalls -join "`n").Contains('-Syu')) 'Private MSYS2 did not initialize signing locally without rolling updates.'
    Remove-Item -LiteralPath (Join-Path $msysRoot 'usr\bin\installed') -ErrorAction SilentlyContinue
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Private MSYS2 bootstrap changed files outside its expected package transaction.'
    $env:PD_MSYS2_PRESERVE_INSTALLED = '1'
    $env:PD_MSYS_FIXTURE_LOG = Join-Path $root 'calls'

    $shellCheck = Join-Path $root 'packages.sh'
    [IO.File]::WriteAllText($shellCheck, @'
set -euo pipefail
. "$1"
PD_MSYS2_ROOT="$2"
PD_MSYS2_PRESERVE_INSTALLED="$3"
PD_MSYS2_READ_ONLY="$4"
PD_MSYS2_PACKAGES_READY=0
pd_install_msys2_packages
'@)
    & $hostBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 1 0
    Assert ($LASTEXITCODE -eq 0) 'Existing Bash package setup failed.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Bash package setup changed reused MSYS2.'
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG).Trim() -ceq 'pacman -Qq') 'Bash package setup ran a modifying command.'
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    & $hostBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 1 1
    Assert ($LASTEXITCODE -eq 0) 'Read-only Bash package setup failed.'
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG) -eq '') 'Read-only Bash package setup queried pacman.'

    $sourceGuard = Join-Path $root 'locked-source-guard.sh'
    [IO.File]::WriteAllText($sourceGuard, @'
set -euo pipefail
PD_DIR="$1"
PD_ROOT="$2"
PD_INSTALL="$PD_ROOT/install"
PD_TEMP="$PD_ROOT/tmp"
PD_REF=7a2be2ebfa45cfc5be78e788a820ee145953f36b
PD_OS=windows
PD_MSYS2_ROOT="$3"
PD_MSYS2_READ_ONLY=0
log() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
. "$PD_DIR/lib/rustifiedgit.sh"
. "$PD_DIR/lib/yazi.sh"
case "$4" in
  rustifiedgit) install_rustifiedgit ;;
  yazi) install_portable_yazi_windows ;;
esac
'@)
    foreach ($feature in @('rustifiedgit', 'yazi')) {
        $guardRoot = ConvertTo-Msys2Path -Path (Join-Path $root 'locked-source-check')
        $ErrorActionPreference = 'Continue'
        $output = & $testBash --noprofile --norc $sourceGuard.Replace('\', '/') `
            $repository.Replace('\', '/') $guardRoot (ConvertTo-Msys2Path -Path $msysRoot) $feature 2>&1
        $guardExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Assert ($guardExit -ne 0 -and ($output -join "`n").Contains('locked offline')) `
            "$feature accepted an unprepared source instead of requiring its locked offline archive."
    }

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
export PD_MSYS2_PACKAGES_READY=1
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
    $launcherExit = $LASTEXITCODE
    $launcherOutput = ($output -join "`n").Replace('\', '/')
    $expectedMsysBin = $msysRoot.Replace('\', '/') + '/ucrt64/bin'
    Assert ($launcherExit -eq 0 -and $launcherOutput.IndexOf($expectedMsysBin, [StringComparison]::OrdinalIgnoreCase) -ge 0) `
        "Launcher did not select the configured MSYS2: exit=$launcherExit; expected=$expectedMsysBin"
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Cross-runtime launcher changed existing MSYS2 files.'

    $nestedRoot = Join-Path $msysRoot 'must-not-create'
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoProfile -File (Join-Path $repository 'install.ps1') `
        -Msys2Root $msysRoot -PlaygroundRoot $nestedRoot 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -ne 0 -and ($output -join "`n").Contains('outside the existing MSYS2')) 'Setup allowed a playground inside existing MSYS2.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Rejected nested playground changed MSYS2.'

    function Find-SystemMsys2 { return $msysRoot }
    $Msys2Root = $null
    $UseExistingMsys2 = $false
    $Msys2SearchPath = $null
    $privateDefault = Join-Path $PlaygroundRoot 'install\msys2'
    $selection = Select-Msys2Root -DefaultRoot $privateDefault -UsePrivateRoot
    Assert ($selection.Root.Equals($privateDefault, [StringComparison]::OrdinalIgnoreCase) -and
        -not $selection.PreserveInstalled) 'Choosing a private MSYS2 unexpectedly searched for or reused a system installation.'
    function Find-SystemMsys2 { return $null }
    $selection = Select-Msys2Root -DefaultRoot $msysRoot
    Assert $selection.PreserveInstalled 'Previously managed MSYS2 was not protected on rerun.'
    $selection = Select-Msys2Root -DefaultRoot (Join-Path $root 'fresh-msys2')
    Assert (-not $selection.PreserveInstalled) 'Fresh MSYS2 installation unexpectedly disabled initialization.'
    Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot 'usr\bin\bash.exe') -Force
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -PreserveInstalled $selection.PreserveInstalled
    $calls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert (@($calls | Where-Object { $_ -like 'bash --noprofile --norc -c *pacman-key --init*' }).Count -eq 1 -and
        -not ($calls -join "`n").Contains('-Syu')) 'Managed MSYS2 did not perform isolated local keyring initialization.'
    & $hostBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 0 0
    Assert ($LASTEXITCODE -eq 0) 'Managed Bash package installation failed.'
    Assert (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\installed')) 'Managed MSYS2 did not install required packages.'
    Copy-Item -LiteralPath $originalBash -Destination $testBash -Force

    foreach ($relative in @('usr\bin\git.exe', 'usr\bin\file.exe', 'ucrt64\bin\cargo.exe', 'ucrt64\bin\rustc.exe')) {
        Remove-Item -LiteralPath (Join-Path $msysRoot $relative) -Force
    }
    $readOnlyRoot = Join-Path $root 'readonly-playground'
    foreach ($relative in @(
        'codex\bin\codex.exe', 'wezterm\v1\wezterm.exe', 'btop\v1\btop.exe',
        'copilot\v1\copilot.exe', 'powershell\v1\pwsh.exe', 'vscode\v1\Code.exe',
        'notepad++\v1\notepad++.exe'
    )) {
        $path = Join-Path (Join-Path $readOnlyRoot 'install') $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        Copy-Item -LiteralPath $driver -Destination $path
    }
    $readOnlyBin = Join-Path $readOnlyRoot 'bin'
    [IO.Directory]::CreateDirectory($readOnlyBin) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $readOnlyRoot 'state')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $readOnlyRoot 'state\windows-commands.tsv'),
        "git`tC:\old\git.exe`nyazi`tC:\old\yazi.exe`nfile`tC:\old\file.exe`n")
    foreach ($name in @('git', 'yazi', 'file')) {
        [IO.File]::WriteAllText((Join-Path $readOnlyBin $name), "#!/bin/sh`n# Managed playground launcher.`n")
        [IO.File]::WriteAllText((Join-Path $readOnlyBin "$name.cmd"), "@echo off`r`nsetlocal`r`n")
    }
    $env:PD_MSYS2_READY = '1'
    $env:PD_MSYS2_READ_ONLY = '1'
    $env:PD_WEZTERM_EXE = Join-Path $readOnlyRoot 'install\wezterm\v1\wezterm.exe'
    $env:PD_BTOP_EXE = Join-Path $readOnlyRoot 'install\btop\v1\btop.exe'
    $env:PD_COPILOT_EXE = Join-Path $readOnlyRoot 'install\copilot\v1\copilot.exe'
    $env:PD_CODE_EXE = Join-Path $readOnlyRoot 'install\vscode\v1\Code.exe'
    $env:PD_NOTEPAD_EXE = Join-Path $readOnlyRoot 'install\notepad++\v1\notepad++.exe'
    $env:PD_PWSH_EXE = Join-Path $readOnlyRoot 'install\powershell\v1\pwsh.exe'
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    $readOnlyBefore = Get-Msys2Snapshot
    $ErrorActionPreference = 'Continue'
    $output = & $testBash --noprofile --norc (Join-Path $repository 'install.sh').Replace('\', '/') `
        --root (ConvertTo-Msys2Path -Path $readOnlyRoot) --msys2-root / --msys2-read-only --no-activate 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -ne 0 -and ($output -join "`n").Contains("Selected command 'git' is unavailable")) `
        ("Read-only setup did not fail explicitly for an unavailable selection: " + ($output -join "`n"))
    $pacmanCalls = @([IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG) | Where-Object { $_ -like 'pacman *' })
    Assert ($pacmanCalls.Count -eq 0) ("Read-only install invoked pacman: " + ($pacmanCalls -join "`n"))
    Assert ((Get-Msys2Snapshot) -ceq $readOnlyBefore) 'Read-only install changed MSYS2 files.'
    $readOnlyManifest = [IO.File]::ReadAllText((Join-Path $readOnlyRoot 'state\windows-commands.tsv'))
    Assert ($readOnlyManifest -ceq "git`tC:\old\git.exe`nyazi`tC:\old\yazi.exe`nfile`tC:\old\file.exe`n") `
        'Failed read-only selection replaced the previous command manifest.'
    $readOnlyOutput = ($output -join "`n")
    Assert ($readOnlyOutput.Contains('Skipping RustifiedGit') -and $readOnlyOutput.Contains('Skipping Yazi')) 'Missing build prerequisites did not skip RustifiedGit and Yazi clearly.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host 'Root-mounted MSYS2, missing-only and read-only packages, dependency guards and preserved tools passed.'
