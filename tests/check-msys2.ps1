#requires -Version 5.1
# Offline fixtures never run an installer or change a real MSYS2 installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$testBash = (Get-Command bash.exe -ErrorAction Stop).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('terminal-msys2-' + [Guid]::NewGuid().ToString('N'))
$msysRoot = Join-Path $root 'msys64'
$PlaygroundRoot = Join-Path $root 'playground'
$helper = Join-Path $repository 'lib\msys2.sh'
$OnlyCodex = $false
$names = @('PD_MSYS2_READ_ONLY', 'PATH', 'BASH_ENV', 'HOME', 'PD_USER_HOME', 'TMPDIR',
    'PD_MSYS_FIXTURE_LOG', 'PD_MSYS_FIXTURE_PACKAGES', 'PD_MSYS_FIXTURE_QUERY_FAIL')
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
    [IO.Directory]::CreateDirectory((Join-Path $PlaygroundRoot 'tmp')) | Out-Null
    $driver = Join-Path $root 'fixture.exe'
    Add-Type -OutputAssembly $driver -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public class Msys2Fixture {
    public static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (name == "cygpath") {
            Console.WriteLine(args[1].Replace('\\', '/'));
            return 0;
        }
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
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "installed"), "fixture");
            return 0;
        }
        return name == "bash" ? 0 : 99;
    }
}
'@
    foreach ($name in @('bash', 'pacman', 'cygpath')) {
        Copy-Item -LiteralPath $driver -Destination (Join-Path $msysRoot "usr\bin\$name.exe")
    }
    $env:PD_MSYS_FIXTURE_LOG = Join-Path $root 'calls'
    $packages = @('bash', 'tmux', 'git', 'file') + @(
        'rust', 'fzf', 'ffmpeg', '7zip', 'jq', 'poppler', 'fd', 'ripgrep', 'zoxide', 'resvg', 'imagemagick'
    ) | ForEach-Object {
        if ($_ -in @('bash', 'tmux', 'git', 'file')) { $_ } else { 'mingw-w64-ucrt-x86_64-' + $_ }
    }
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $env:PD_MSYS_FIXTURE_QUERY_FAIL = '0'
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Test-Msys2Installation', 'Select-Msys2Root', 'ConvertTo-Msys2Path', 'Initialize-Msys2')) {
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
    }
    function Find-SystemMsys2 { return $msysRoot }
    function Invoke-Checked {
        param([string] $Program, [string[]] $Arguments)
        $ErrorActionPreference = 'Continue'
        if ($env:PD_MSYS2_READ_ONLY -eq '1') {
            Assert ($Arguments[0] -eq '--noprofile' -and $Arguments[1] -eq '--norc') 'Read-only setup loaded shell startup files.'
            $Program = $testBash
        }
        $output = & $Program @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    }
    $before = Get-Msys2Snapshot
    foreach ($explicitRoot in @($true, $false)) {
        $Msys2Root = if ($explicitRoot) { $msysRoot } else { $null }
        $UseExistingMsys2 = -not $explicitRoot
        $selection = Select-Msys2Root -DefaultRoot (Join-Path $PlaygroundRoot 'install\msys2')
        Assert $selection.ReadOnly 'Reused MSYS2 was not marked read-only.'
        $env:BASH_ENV = Join-Path $msysRoot 'startup-must-not-run'
        $env:HOME = Join-Path $msysRoot 'home'
        Initialize-Msys2 -ReadOnly $selection.ReadOnly
        Assert (-not $env:BASH_ENV) 'Read-only setup inherited BASH_ENV.'
        Assert ($env:HOME.StartsWith($PlaygroundRoot.Replace('\', '/'))) 'Build home is not isolated from reused MSYS2.'
        Assert ((Get-Msys2Snapshot) -ceq $before) 'Read-only preflight changed MSYS2.'
    }
    $calls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert ($calls.Count -eq 2 -and @($calls | Where-Object { $_ -cne 'pacman -Qq' }).Count -eq 0) 'Read-only preflight ran a modifying command.'

    foreach ($failure in @('missing', 'database')) {
        $env:PD_MSYS_FIXTURE_PACKAGES = ($packages | Where-Object { $_ -ne 'tmux' }) -join "`n"
        $env:PD_MSYS_FIXTURE_QUERY_FAIL = if ($failure -eq 'database') { '1' } else { '0' }
        $message = ''
        try { Initialize-Msys2 -ReadOnly $true } catch { $message = $_.Exception.Message }
        $expected = if ($failure -eq 'database') { 'Could not read the existing MSYS2 package database' } else { 'Missing required packages: tmux' }
        Assert ($message.Contains($expected)) "Preflight did not report $failure prerequisites: $message"
        Assert ((Get-Msys2Snapshot) -ceq $before) 'Failed preflight changed MSYS2.'
    }
    $env:PD_MSYS_FIXTURE_PACKAGES = $packages -join "`n"
    $env:PD_MSYS_FIXTURE_QUERY_FAIL = '0'
    $OnlyCodex = $true
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -ReadOnly $true
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG) -eq '') 'Codex-only setup queried or modified MSYS2 packages.'
    $OnlyCodex = $false

    $shellCheck = Join-Path $root 'packages.sh'
    [IO.File]::WriteAllText($shellCheck, @'
set -euo pipefail
. "$1"
PD_MSYS2_ROOT="$2"
PD_MSYS2_READ_ONLY="$3"
pd_install_msys2_packages
'@)
    & $testBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 1
    Assert ($LASTEXITCODE -eq 0) 'Read-only Bash package setup failed.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Bash package setup changed reused MSYS2.'
    Assert ([IO.File]::ReadAllText($env:PD_MSYS_FIXTURE_LOG).Trim() -ceq 'pacman -Qq') 'Bash package setup ran a modifying command.'

    $nestedRoot = Join-Path $msysRoot 'must-not-create'
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoProfile -File (Join-Path $repository 'install.ps1') `
        -Msys2Root $msysRoot -PlaygroundRoot $nestedRoot 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -ne 0 -and ($output -join "`n").Contains('outside the read-only MSYS2')) 'Setup allowed a playground inside read-only MSYS2.'
    Assert ((Get-Msys2Snapshot) -ceq $before) 'Rejected nested playground changed MSYS2.'

    function Find-SystemMsys2 { return $null }
    $Msys2Root = $null
    $UseExistingMsys2 = $false
    $selection = Select-Msys2Root -DefaultRoot $msysRoot
    Assert (-not $selection.ReadOnly) 'Managed MSYS2 unexpectedly became read-only.'
    [IO.File]::WriteAllText($env:PD_MSYS_FIXTURE_LOG, '')
    Initialize-Msys2 -ReadOnly $selection.ReadOnly
    $calls = [IO.File]::ReadAllLines($env:PD_MSYS_FIXTURE_LOG)
    Assert (@($calls | Where-Object { $_ -eq 'bash --login -c pacman --noconfirm -Syu' }).Count -eq 2) 'Managed MSYS2 no longer performs both system upgrade passes.'
    & $testBash --noprofile --norc $shellCheck.Replace('\', '/') $helper.Replace('\', '/') $msysRoot.Replace('\', '/') 0
    Assert ($LASTEXITCODE -eq 0) 'Managed Bash package installation failed.'
    Assert (Test-Path -LiteralPath (Join-Path $msysRoot 'usr\bin\installed')) 'Managed MSYS2 did not install required packages.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host 'Read-only MSYS2 reuse and managed package installation passed.'
