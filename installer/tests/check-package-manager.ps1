#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'lib\packages.ps1')
$base = Join-Path ([IO.Path]::GetTempPath()) ('package-manager-' + [Guid]::NewGuid().ToString('N'))
$PlaygroundRoot = Join-Path $base 'original'
$installRoot = Join-Path $PlaygroundRoot 'install'
$cacheDirectory = Join-Path $PlaygroundRoot 'cache'
$configDirectory = Join-Path $PlaygroundRoot 'config'
$binDirectory = Join-Path $PlaygroundRoot 'bin'
$msysRoot = Join-Path $installRoot 'msys2'
$PackageDirectory = Join-Path $base 'bundle'
$Offline = $true
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$envNames = @('TEMP', 'TMP', 'HOME', 'XDG_CONFIG_HOME', 'PD_PWSH_EXE', 'PD_DEVTOOLS_ROOT')
$saved = @{}
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Failure([scriptblock] $Action, [string] $Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert $failed $Message
}
function Invoke-WebRequest { throw 'Offline tests must not make network requests.' }
try {
    foreach ($directory in @($cacheDirectory, $PackageDirectory, $binDirectory, (Join-Path $PlaygroundRoot 'tmp'), (Join-Path $PlaygroundRoot 'state'))) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $env:TEMP = Join-Path $PlaygroundRoot 'tmp'; $env:TMP = $env:TEMP
    $fixture = Join-Path $base 'fixture.exe'
    Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
public class PackageFixture {
    public static void Main() {
        Console.WriteLine("config=" + Environment.GetEnvironmentVariable("XDG_CONFIG_HOME"));
        Console.WriteLine("home=" + Environment.GetEnvironmentVariable("HOME"));
        Console.WriteLine("path=" + Environment.GetEnvironmentVariable("PATH"));
    }
}
'@
    $zip = Join-Path $base 'fixture.zip'
    Compress-Archive -LiteralPath $fixture -DestinationPath $zip
    $sha = (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
    $url = 'https://example.invalid/fixture.zip'
    $bundleFile = Join-Path $PackageDirectory ($sha + '-fixture.zip')
    Copy-Item -LiteralPath $zip -Destination $bundleFile
    Save-PDLockedFiles @([pscustomobject]@{Url=$url; Sha256=$sha})
    $cached = Save-PDLockedFile $url $sha
    Assert ((Get-FileHash -LiteralPath $cached).Hash -ieq $sha) 'Local bundle was not verified.'
    [IO.File]::WriteAllText($cached, 'corrupt cache')
    Assert-Failure { Save-PDLockedFile $url $sha } 'Corrupt cache was silently reused.'
    Remove-Item -LiteralPath $cached
    [IO.File]::WriteAllText($bundleFile, 'corrupt bundle')
    Assert-Failure { Save-PDLockedFile $url $sha } 'Corrupt offline bundle was accepted.'
    Remove-Item -LiteralPath $bundleFile
    Assert-Failure { Save-PDLockedFile $url $sha } 'Missing offline archive succeeded.'
    Copy-Item -LiteralPath $zip -Destination $bundleFile
    $script:fixturePackage = [pscustomobject]@{ Id='fixture'; Version='1'; Sha256=$sha; Url=$url; Archive='zip' }
    function Get-PDPackage { param([string] $Id); return $script:fixturePackage }
    $target = Install-PDArchive fixture fixture fixture.exe
    Assert ((Test-Path -LiteralPath $target)) 'Verified archive did not install.'
    Assert ((Install-PDArchive fixture fixture fixture.exe) -ceq $target) 'Repeat install changed the active executable.'
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'install.ps1'), [ref]$null, [ref]$null)
    $findDefinition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-InstalledTool'
    }, $true)
    Set-Item Function:Find-InstalledTool $findDefinition.Body.GetScriptBlock()
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-WindowsLaunchers'
    }, $true)
    Set-Item Function:Write-WindowsLaunchers $definition.Body.GetScriptBlock()
    $devtoolsRoot = Join-Path $base 'd_t'
    $devtoolsGitBin = Join-Path $devtoolsRoot 'bin\PortableGit\cmd'
    [IO.Directory]::CreateDirectory($devtoolsGitBin) | Out-Null
    [IO.File]::WriteAllText((Join-Path $devtoolsGitBin 'git.exe'), 'fixture')
    [IO.Directory]::CreateDirectory((Join-Path $PlaygroundRoot 'config\path')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $PlaygroundRoot 'config\path\devtools-root.txt'), $devtoolsRoot)
    [IO.File]::WriteAllText((Join-Path $PlaygroundRoot 'state\windows-commands.tsv'),
        "fixture`tinstall\fixture\1\fixture.exe`ngit`tinstall\fixture\1\fixture.exe`nrustifiedgit`tinstall\fixture\1\fixture.exe`n")
    $env:HOME = 'caller-home'; $env:XDG_CONFIG_HOME = 'caller-config'
    $env:PD_DEVTOOLS_ROOT = $null
    Write-WindowsLaunchers
    $moved = Join-Path $base 'moved'
    Move-Item -LiteralPath $PlaygroundRoot -Destination $moved
    $env:TEMP = Join-Path $moved 'tmp'; $env:TMP = $env:TEMP
    $output = & (Join-Path $moved 'bin\fixture.cmd')
    Assert ($LASTEXITCODE -eq 0) 'Relocated launcher could not execute.'
    $launcherOutput = $output -join "`n"
    Assert ($launcherOutput.IndexOf("config=$moved\config", [StringComparison]::OrdinalIgnoreCase) -ge 0) 'Relocated launcher used the old configuration root.'
    Assert ($launcherOutput.IndexOf("home=$moved\state\home", [StringComparison]::OrdinalIgnoreCase) -ge 0) 'Child HOME escaped the relocated folder.'
    $output = & (Join-Path $moved 'bin\git.cmd')
    Assert (($output -join "`n").Contains('home=caller-home') -and
        ($output -join "`n").Contains('config=caller-config')) 'Direct Git changed caller configuration discovery.'
    $output = & (Join-Path $moved 'bin\rustifiedgit.cmd')
    Assert ($LASTEXITCODE -eq 0) 'RustifiedGit launcher could not execute.'
    Assert (($output -join "`n").Contains("path=$devtoolsGitBin;")) `
        'RustifiedGit did not prioritize the configured Windows Git executable.'
    $PlaygroundRoot = $moved
    $installRoot = Join-Path $moved 'install'
    $binDirectory = Join-Path $moved 'bin'
    $configDirectory = Join-Path $moved 'config'
    $cacheDirectory = Join-Path $moved 'cache'
    $msysRoot = Join-Path $installRoot 'msys2'
    $manifest = Join-Path $moved 'state\windows-commands.tsv'
    $copilot = Join-Path $moved 'install\copilot\v1\copilot.exe'
    $pwsh = Join-Path $moved 'install\powershell\v1\pwsh.exe'
    foreach ($path in @($copilot, $pwsh)) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, 'fixture')
    }
    [IO.File]::WriteAllText($manifest,
        "copilot`tinstall\copilot\v1\copilot.exe`npwsh`tinstall\powershell\v1\pwsh.exe`n")
    $env:PD_PWSH_EXE = $null
    Write-WindowsLaunchers
    $copilotLauncher = [IO.File]::ReadAllText((Join-Path $binDirectory 'copilot.cmd'))
    $pwshDirectory = (Split-Path -Parent $pwsh).Replace($moved, '%PD_ROOT%')
    Assert ($copilotLauncher.Contains('set "PATH=' + $pwshDirectory + ';%PATH%"')) `
        'The Copilot launcher did not resolve PowerShell from the relocated managed installation.'
    [IO.File]::WriteAllText($manifest, "../escape`tinstall\fixture\1\fixture.exe`n")
    Assert-Failure { Write-WindowsLaunchers } 'Unsafe command name escaped the launcher directory.'
    [IO.File]::WriteAllText($manifest, "fixture`tC:\Windows\System32\cmd.exe`n")
    Assert-Failure { Write-WindowsLaunchers } 'External command target was silently accepted.'
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Configure-Btop'
    }, $true)
    Set-Item Function:Configure-Btop $definition.Body.GetScriptBlock()
    function Invoke-Checked {
        param([string] $Program, [string[]] $Arguments)
        & $Program @Arguments | Out-Null
        if ($LASTEXITCODE) { throw 'Fixture command failed.' }
    }
    [IO.Directory]::CreateDirectory((Join-Path $configDirectory 'btop')) | Out-Null
    $central = Join-Path $configDirectory 'btop\btop.conf'
    $bundled = Join-Path (Split-Path -Parent (Join-Path $moved 'install\fixture\1\fixture.exe')) 'btop.conf'
    [IO.File]::WriteAllText($central, 'copied configuration')
    [IO.File]::WriteAllText($bundled, 'copied configuration')
    Configure-Btop (Join-Path $moved 'install\fixture\1\fixture.exe')
    Configure-Btop (Join-Path $moved 'install\fixture\1\fixture.exe')
    [IO.File]::WriteAllText($central, 'user customization')
    Assert ([IO.File]::ReadAllText($bundled) -ceq 'user customization') 'Copied btop configurations were not relinked.'
    Remove-Item -LiteralPath $bundled
    [IO.File]::WriteAllText($bundled, 'divergent customization')
    Assert-Failure { Configure-Btop (Join-Path $moved 'install\fixture\1\fixture.exe') } 'Divergent btop configurations were overwritten.'
    $partial = Join-Path $moved 'tmp\async-fixture'
    Copy-Item -LiteralPath $zip -Destination $partial
    $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
    $completion.SetResult($null)
    $output = @(Complete-PDLockedDownload ([pscustomobject]@{
        Task=$completion.Task; Started=[DateTime]::UtcNow; Partial=$partial
        Destination=(Join-Path $moved 'cache\async-fixture'); Sha256=$sha; Url=$url
    }))
    Assert ($output.Count -eq 0) 'Concurrent downloader leaked task results into build source paths.'
    $failedCompletion = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
    $failedCompletion.SetException([InvalidOperationException]::new('fixture network failure'))
    $failureMessage = ''
    try {
        Complete-PDLockedDownload ([pscustomobject]@{
            Task=$failedCompletion.Task; Started=[DateTime]::UtcNow
            Partial=(Join-Path $moved 'tmp\failed-async-fixture')
            Destination=(Join-Path $moved 'cache\failed-async-fixture'); Sha256=$sha; Url=$url
        })
    } catch { $failureMessage = $_.Exception.Message }
    Assert ($failureMessage.Contains('fixture network failure')) 'The concurrent downloader hid the underlying network error.'
    $badZip = Join-Path $base 'traversal.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    try { $entry = $archive.CreateEntry('../escape.txt'); $stream = $entry.Open(); $stream.Dispose() }
    finally { $archive.Dispose() }
    Assert-Failure { Expand-PDLockedArchive $badZip zip (Join-Path $base 'unsafe') } 'Archive traversal was accepted.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $base 'escape.txt'))) 'Archive wrote outside staging.'
    Assert ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $userPath) 'Package installation modified persistent PATH.'
    Write-Host 'Verified offline packages, failures, reruns and relocated native launchers passed.'
} finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
