# Native Windows downloads use the OS HTTPS trust policy, never a custom CA bundle.
function Get-PDPackage {
    param([string] $Id, [string] $Platform = 'windows-x64')
    $records = @()
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\packages\artifacts.tsv'))) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if ($parts.Count -ne 8 -or $parts[3] -notmatch '^[a-f0-9]{64}$' -or $parts[4] -notmatch '^https://') {
            throw "Invalid package lock record: $line"
        }
        if ($parts[0] -eq $Id -and $parts[1] -in @($Platform, 'all')) {
            $records += [pscustomobject]@{
                Id = $parts[0]; Platform = $parts[1]; Version = $parts[2]; Sha256 = $parts[3]
                Url = $parts[4]; Archive = $parts[5]; Executable = $parts[6]; Repository = $parts[7]
            }
        }
    }
    if ($records.Count -ne 1) { throw "No unique reviewed package for $Id on $Platform. No package was installed." }
    return $records[0]
}

function Save-PDLockedFile {
    param([string] $Url, [string] $Sha256)
    if ($Sha256 -notmatch '^[a-f0-9]{64}$' -or $Url -notmatch '^https://') { throw 'Invalid locked download.' }
    $filename = $Sha256 + '-' + [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    $destination = Join-Path $cacheDirectory $filename
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $Sha256) {
            throw "Cached package was modified: $destination"
        }
        return $destination
    }
    if ($PackageDirectory) {
        $candidate = Join-Path $PackageDirectory $filename
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $Sha256) {
                throw "Offline package failed SHA-256 verification: $candidate"
            }
            Copy-Item -LiteralPath $candidate -Destination $destination
            return $destination
        }
    }
    if ($Offline) { throw "Offline package is missing: $filename" }
    $partial = Join-Path (Join-Path $PlaygroundRoot 'tmp') ([Guid]::NewGuid().ToString('N') + '-' + $filename)
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $Sha256) {
            throw "SHA-256 verification failed for $Url"
        }
        Move-Item -LiteralPath $partial -Destination $destination
    } catch {
        throw "Package download failed for $Url. Windows HTTPS trust was left unchanged; supply a verified offline bundle if access is restricted. $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    return $destination
}

function Complete-PDLockedDownload {
    param([object] $Download)
    try {
        $remaining = [Math]::Max(0, 180000 - ([DateTime]::UtcNow - $Download.Started).TotalMilliseconds)
        $completed = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($Download.Task), [int]$remaining)
        if ($completed -lt 0) { throw 'Download timed out after 180 seconds.' }
        $Download.Task.GetAwaiter().GetResult() | Out-Null
        if ((Get-FileHash -LiteralPath $Download.Partial).Hash -ine $Download.Sha256) { throw 'SHA-256 mismatch.' }
        Move-Item -LiteralPath $Download.Partial -Destination $Download.Destination
    } catch {
        $failure = $_.Exception
        if ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) {
            $failure = $failure.InnerException
        }
        if ($failure -is [System.AggregateException]) {
            $detail = ($failure.Flatten().InnerExceptions | ForEach-Object { $_.Message }) -join '; '
        } else {
            $detail = $failure.Message
        }
        throw "Package download failed for $($Download.Url). Windows HTTPS trust was left unchanged; supply a verified offline bundle if access is restricted. $detail"
    }
}

function Save-PDLockedFiles {
    param([object[]] $Files)
    $pending = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($item in @($Files | Sort-Object Sha256,Url -Unique)) {
            $filename = $item.Sha256 + '-' + [IO.Path]::GetFileName(([Uri]$item.Url).AbsolutePath)
            if ($item.Sha256 -notmatch '^[a-f0-9]{64}$' -or $item.Url -notmatch '^https://') { throw 'Invalid bundle record.' }
            if ($Offline -or $PackageDirectory -or (Test-Path -LiteralPath (Join-Path $cacheDirectory $filename))) {
                Save-PDLockedFile $item.Url $item.Sha256 | Out-Null
                continue
            }
            $partial = Join-Path (Join-Path $PlaygroundRoot 'tmp') ([Guid]::NewGuid().ToString('N') + '-' + $filename)
            $client = New-Object Net.WebClient
            $pending.Add([pscustomobject]@{
                Client = $client; Task = $client.DownloadFileTaskAsync([Uri]$item.Url, $partial)
                Started = [DateTime]::UtcNow
                Partial = $partial; Destination = (Join-Path $cacheDirectory $filename); Sha256 = $item.Sha256; Url = $item.Url
            })
            if ($pending.Count -ge 6) {
                $download = $pending[0]
                Complete-PDLockedDownload $download
                $download.Client.Dispose()
                $pending.RemoveAt(0)
            }
        }
        foreach ($download in $pending) {
            Complete-PDLockedDownload $download
        }
    } finally {
        foreach ($download in $pending) {
            $download.Client.CancelAsync()
            $download.Client.Dispose()
            if (Test-Path -LiteralPath $download.Partial) { Remove-Item -LiteralPath $download.Partial -Force }
        }
    }
}

function Expand-PDLockedArchive {
    param([string] $File, [string] $Archive, [string] $Destination)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    if ($Archive -eq 'zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($File)
        try {
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.Replace('/', '\')
                $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
                if ([IO.Path]::IsPathRooted($name) -or $name -match ':' -or
                    -not $target.StartsWith($Destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw "Unsafe archive entry: $name"
                }
            }
        } finally { $zip.Dispose() }
        Expand-Archive -LiteralPath $File -DestinationPath $Destination
    } elseif ($Archive -in @('tar.gz', 'source')) {
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        $entries = & $tar -tzf $File
        if ($LASTEXITCODE) { throw "Cannot inspect archive: $File" }
        foreach ($name in $entries) {
            if ($name -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)') { throw "Unsafe archive entry: $name" }
        }
        Invoke-Checked -Program $tar -Arguments @('-xzf', $File, '-C', $Destination, '--strip-components=1')
    } else { throw "Unsupported Windows archive type: $Archive" }
}

function Install-PDArchive {
    param([string] $Id, [string] $Name, [string] $Executable)
    $package = Get-PDPackage $Id
    $destination = Join-Path (Join-Path $installRoot $Name) $package.Version
    $record = Join-Path $destination '.terminal-package.json'
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        $installed = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        $target = Join-Path $destination $installed.executable
        if ($installed.sha256 -cne $package.Sha256 -or
            -not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target).Hash -ine $installed.executableSha256) {
            throw "Installed $Id is incomplete or modified. No installed version was replaced."
        }
        return $target
    }
    if (Test-Path -LiteralPath $destination) { throw "Incomplete package directory: $destination. Remove that directory explicitly before retrying." }
    $file = Save-PDLockedFile $package.Url $package.Sha256
    $staging = Join-Path (Join-Path $PlaygroundRoot 'tmp') ('package-' + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-PDLockedArchive $file $package.Archive $staging
        $found = @(Get-ChildItem -LiteralPath $staging -Recurse -File -Filter $Executable)
        if ($found.Count -ne 1) { throw "Expected one $Executable in $Id." }
        $relative = $found[0].FullName.Substring($staging.Length + 1)
        $metadata = @{ id = $Id; version = $package.Version; sha256 = $package.Sha256
            executable = $relative; executableSha256 = (Get-FileHash -LiteralPath $found[0].FullName).Hash }
        [IO.File]::WriteAllText((Join-Path $staging '.terminal-package.json'), ($metadata | ConvertTo-Json))
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Move-Item -LiteralPath $staging -Destination $destination
        return (Join-Path $destination $relative)
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function Get-PDMsys2Packages {
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\packages\msys2.windows-x64.tsv'))) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if (($parts.Count -ne 6 -and $parts.Count -ne 7) -or $parts[1] -notmatch '^[A-Za-z0-9+_.-]+$' -or
            $parts[4] -notmatch '^[a-f0-9]{64}$') { throw "Invalid MSYS2 lock: $line" }
        $signature = if ($parts.Count -eq 7) { $parts[6] } else { '' }
        if (Test-PDSelected $parts[0]) {
            [pscustomobject]@{ Feature = $parts[0]; Name = $parts[1]; Version = $parts[2]; Filename = $parts[3]; Sha256 = $parts[4]; Url = $parts[5]; Signature = $signature }
        }
    }
}

function Install-PDLockedMsys2Packages {
    if ($Msys2ReadOnly) { return }
    $packages = @(Get-PDMsys2Packages | Sort-Object Name -Unique)
    if (-not $packages.Count) { return }
    $installed = & (Join-Path $msysRoot 'usr\bin\pacman.exe') -Qq
    if ($LASTEXITCODE) { throw 'Cannot read the private package database.' }
    $packages = @($packages | Where-Object { $_.Name -notin $installed })
    if (-not $packages.Count) { return }
    Write-Host "[playground] Preparing $($packages.Count) missing locked MSYS2 packages."
    Save-PDLockedFiles $packages
    # Local archives are already hash-locked; pacman's signature checks remain enabled.
    $helper = ConvertTo-Msys2Path (Join-Path $PSScriptRoot 'msys2.sh')
    $repository = ConvertTo-Msys2Path (Split-Path -Parent $PSScriptRoot)
    $unixRoot = ConvertTo-Msys2Path $msysRoot
    $transaction = Join-Path (Join-Path $PlaygroundRoot 'tmp') ('msys2-transaction-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($transaction) | Out-Null
    try {
        $names = @()
        foreach ($package in $packages) {
            if ($package.Name -notmatch '^[A-Za-z0-9+_.-]+$') { throw 'Invalid package name.' }
            $archive = Save-PDLockedFile $package.Url $package.Sha256
            $name = $package.Name + '.pkg.tar.zst'
            $alias = Join-Path $transaction $name
            New-Item -ItemType HardLink -Path $alias -Target $archive | Out-Null
            if ($package.Signature) { [IO.File]::WriteAllBytes(($alias + '.sig'), [Convert]::FromBase64String($package.Signature)) }
            $names += $name
        }
        if (($names -join ' ').Length -gt 24000) { throw 'Locked package transaction exceeds the native argument limit; review its dependency closure.' }
        [IO.File]::WriteAllText((Join-Path $transaction 'files.txt'), (($names -join "`n") + "`n"), [Text.Encoding]::ASCII)
        $arguments = @('--noprofile', '--norc', $helper, $unixRoot,
            '--locked', $repository, (ConvertTo-Msys2Path $transaction))
        Invoke-Checked -Program (Join-Path $msysRoot 'usr\bin\bash.exe') -Arguments $arguments
    } finally {
        Remove-Item -LiteralPath $transaction -Recurse -Force
    }
}

function Initialize-PDVendor {
    param([string] $Feature)
    $vendor = Join-Path $cacheDirectory 'vendor'
    [IO.Directory]::CreateDirectory($vendor) | Out-Null
    $downloads = @()
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\packages\crates.windows-x64.tsv'))) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if ($parts[0] -eq $Feature) { $downloads += [pscustomobject]@{Url = $parts[4]; Sha256 = $parts[3]} }
    }
    Save-PDLockedFiles $downloads
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\packages\crates.windows-x64.tsv'))) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split([char]9)
        if ($parts.Count -ne 5 -or $parts[3] -notmatch '^[a-f0-9]{64}$') { throw "Invalid crate lock: $line" }
        if ($parts[0] -ne $Feature) { continue }
        $directory = Join-Path $vendor ($parts[1] + '-' + $parts[2])
        if (Test-Path -LiteralPath (Join-Path $directory '.cargo-checksum.json')) { continue }
        $file = Save-PDLockedFile $parts[4] $parts[3]
        $staging = Join-Path (Join-Path $PlaygroundRoot 'tmp') ('crate-' + [Guid]::NewGuid().ToString('N'))
        try {
            Expand-PDLockedArchive $file source $staging
            $checksum = $parts[3]
            if ($parts[4] -match '^https://github.com/') {
                $toml = Join-Path $PSScriptRoot ('..\packages\vendor-manifests\' + $parts[1] + '-' + $parts[2] + '.toml')
                $nested = @(Get-ChildItem -LiteralPath $staging -Filter Cargo.toml -Recurse | Where-Object {
                    [IO.File]::ReadAllText($_.FullName) -match ('(?m)^name\s*=\s*"' + [regex]::Escape($parts[1]) + '"')
                })
                if ($nested.Count -ne 1) { throw "Missing vendored Git crate $($parts[1])" }
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                Copy-Item -Path (Join-Path $nested[0].DirectoryName '*') -Destination $directory -Recurse
                Copy-Item -LiteralPath $toml -Destination (Join-Path $directory 'Cargo.toml') -Force
                $checksum = $null
            } else {
                Move-Item -LiteralPath $staging -Destination $directory
            }
            $files = @{}
            foreach ($item in Get-ChildItem -LiteralPath $directory -Recurse -File) {
                $relative = $item.FullName.Substring($directory.Length + 1).Replace('\', '/')
                $files[$relative] = (Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant()
            }
            [IO.File]::WriteAllText((Join-Path $directory '.cargo-checksum.json'), (@{files = $files; package = $checksum} | ConvertTo-Json -Depth 4))
        } finally {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        }
    }
    return $vendor
}

function Prepare-PDWindowsBuild {
    param([string] $Feature)
    $package = Get-PDPackage ($Feature + '-source')
    $source = Join-Path (Join-Path $PlaygroundRoot 'tmp') ($Feature + '-source-' + [Guid]::NewGuid().ToString('N'))
    $archive = Save-PDLockedFile $package.Url $package.Sha256
    Expand-PDLockedArchive $archive source $source
    $vendor = Initialize-PDVendor $Feature
    $cargoConfig = Join-Path $source '.cargo'
    [IO.Directory]::CreateDirectory($cargoConfig) | Out-Null
    $vendorLiteral = $vendor.Replace('\', '/')
    $configuration = @"
[source.crates-io]
replace-with = "vendored"
[source.vendored]
directory = "$vendorLiteral"
[net]
offline = true
"@
    if ($Feature -eq 'yazi') {
        $configuration += @"

[source.ratatui]
git = "https://github.com/yazi-rs/ratatui.git"
branch = "fix_buffer_diff_wide_cells"
replace-with = "vendored"
"@
    }
    [IO.File]::WriteAllText((Join-Path $cargoConfig 'config.toml'), $configuration, [Text.Encoding]::ASCII)
    return $source
}
