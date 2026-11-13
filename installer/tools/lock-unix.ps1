# Optional maintainer operation; installers consume committed locks, never solve.
[CmdletBinding()]
param(
    [string]$Micromamba = '.ci-playground\lock-tmp\micromamba.exe',
    [string]$ChannelDirectory = '.ci-playground\unix-lock\channel',
    [string]$WorkDirectory = '.ci-playground\unix-lock',
    [string]$OutputDirectory = 'packages',
    [ValidateSet('linux-x64', 'linux-arm64', 'macos-x64', 'macos-arm64')]
    [string[]]$TargetPlatform = @('linux-x64', 'linux-arm64', 'macos-x64', 'macos-arm64'),
    [switch]$DownloadMetadata,
    [switch]$SupplementHistoricalHarfbuzz
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
foreach ($path in @($WorkDirectory, $OutputDirectory, $ChannelDirectory)) {
    $full = [IO.Path]::GetFullPath((Join-Path $repository $path))
    if (-not $full.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Maintainer outputs and metadata must stay inside the repository.'
    }
}
$work = [IO.Path]::GetFullPath((Join-Path $repository $WorkDirectory))
$channel = [IO.Path]::GetFullPath((Join-Path $repository $ChannelDirectory))
$out = [IO.Path]::GetFullPath((Join-Path $repository $OutputDirectory))
$mamba = [IO.Path]::GetFullPath((Join-Path $repository $Micromamba))
if ((Get-FileHash $mamba -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f8b4284bd4eb1134122eaf93b3ea6c7be567e596de5829e1a6f478e34e41974a') {
    throw 'Expected the reviewed native Windows micromamba 2.10.0 artifact.'
}
New-Item -ItemType Directory -Force -Path $work, $out | Out-Null
$platforms = [ordered]@{
    'linux-x64' = 'linux-64'
    'linux-arm64' = 'linux-aarch64'
    'macos-x64' = 'osx-64'
    'macos-arm64' = 'osx-arm64'
}
if ($DownloadMetadata) {
    foreach ($subdir in @($platforms.Values) + @('noarch')) {
        $destination = Join-Path $channel $subdir
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        # Native Windows system trust; no curl CA additions or TLS bypass.
        Invoke-WebRequest -UseBasicParsing -Uri "https://conda.anaconda.org/conda-forge/$subdir/current_repodata.json" `
            -OutFile (Join-Path $destination 'repodata.json')
    }
}
if ($SupplementHistoricalHarfbuzz) {
        Get-Command node -ErrorAction Stop | Out-Null
        $supplements = @()
        foreach ($packageName in @('harfbuzz', 'libharfbuzz', 'libharfbuzz-devel', 'libglib', 'glib-tools')) {
            $supplement = Join-Path $work "$packageName.json"
            Invoke-WebRequest -UseBasicParsing -Uri "https://api.anaconda.org/package/conda-forge/$packageName" -OutFile $supplement
            $supplements += $supplement
        }
        $privateChannel = Join-Path $work 'supplemented-channel'
        foreach ($subdir in @($platforms.Values) + @('noarch')) {
            $destination = Join-Path $privateChannel $subdir
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-Item (Join-Path (Join-Path $channel $subdir) 'repodata.json') (Join-Path $destination 'repodata.json')
        }
        # Historical library builds bridge the frozen ICU/gettext transitions.
        # Never edit a supplied/shared channel in place.
        @'
    const fs = require('fs'), path = require('path');
    const [directory, ...metadata] = process.argv.slice(2);
    const files = metadata.flatMap(filename => JSON.parse(fs.readFileSync(filename)).files);
    for (const subdir of ['linux-64', 'linux-aarch64', 'osx-64', 'osx-arm64']) {
      const filename = path.join(directory, subdir, 'repodata.json');
      const repodata = JSON.parse(fs.readFileSync(filename));
      for (const p of files.filter(p => ['13.2.1', '14.2.1', '14.5.0', '14.6.0', '2.88.3', '2.90.0'].includes(p.version) &&
          p.attrs.subdir === subdir && p.labels.includes('main'))) {
        if (!/^[a-f0-9]{64}$/.test(p.sha256)) throw Error('Missing historical SHA-256');
        const record = {...p.attrs, name: p.full_name.split('/')[1], version: p.version,
          sha256: p.sha256, md5: p.md5, size: p.size};
        const name = p.basename.split('/').pop();
        (name.endsWith('.conda') ? repodata['packages.conda'] : repodata.packages)[name] = record;
      }
      fs.writeFileSync(filename, JSON.stringify(repodata));
    }
'@ | node - $privateChannel @supplements
        if ($LASTEXITCODE -ne 0) { throw 'Historical metadata supplementation failed.' }
        $channel = $privateChannel
}
foreach ($subdir in @($platforms.Values) + @('noarch')) {
    if (-not (Test-Path (Join-Path (Join-Path $channel $subdir) 'repodata.json'))) {
        throw "Missing $subdir metadata. Supply a local channel or use -DownloadMetadata."
    }
}
$groups = [ordered]@{
    bash = @('bash=5.3')
    git = @('git=2.56.1')
    tmux = @('tmux=3.8_')
    fzf = @('fzf=0.75.0')
    btop = @('btop=1.4.8')
    yazi = @('yazi=26.9.1')
    'yazi-file' = @('file=5.48')
    'yazi-ffmpeg' = @('ffmpeg=9.0.2')
    'yazi-7zip' = @('7zip=26.06')
    'yazi-jq' = @('jq=1.8.2')
    'yazi-poppler' = @('poppler=26.11.0')
    'yazi-fd' = @('fd-find=10.5.2')
    'yazi-ripgrep' = @('ripgrep=15.2.0')
    'yazi-zoxide' = @('zoxide=0.10.0')
    'yazi-resvg' = @('resvg=0.49.0')
    'yazi-imagemagick' = @('imagemagick=7.1.2_31', 'ghostscript=10.08.0')
}
$environmentNames = @('HOME', 'USERPROFILE', 'MAMBA_ROOT_PREFIX', 'CONDA_PKGS_DIRS',
    'CONDA_ENVS_PATH', 'CONDA_OVERRIDE_GLIBC', 'CONDA_OVERRIDE_OSX',
    'CONDA_OVERRIDE_LINUX', 'CONDA_OVERRIDE_CUDA', 'CONDA_OVERRIDE_ARCHSPEC',
    'TEMP', 'TMP', 'TMPDIR')
$saved = @{}
foreach ($name in $environmentNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($dir in @('home', 'tmp', 'mamba-root', 'pkgs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $work $dir) | Out-Null
    }
    $env:HOME = Join-Path $work 'home'
    $env:USERPROFILE = $env:HOME
    $env:MAMBA_ROOT_PREFIX = Join-Path $work 'mamba-root'
    $env:CONDA_PKGS_DIRS = Join-Path $work 'pkgs'
    $env:CONDA_ENVS_PATH = Join-Path $work 'envs'
    $env:TEMP = Join-Path $work 'tmp'
    $env:TMP = $env:TEMP
    $env:TMPDIR = $env:TEMP
    $env:CONDA_OVERRIDE_CUDA = ''
    $channelUri = ([Uri]($channel + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri.TrimEnd('/')
    foreach ($platform in $TargetPlatform) {
        $subdir = $platforms[$platform]
        $env:CONDA_OVERRIDE_GLIBC = '2.28'
        $env:CONDA_OVERRIDE_LINUX = '4.18'
        $env:CONDA_OVERRIDE_OSX = if ($platform -eq 'macos-arm64') { '14.5' } else { '13.0' }
        $env:CONDA_OVERRIDE_ARCHSPEC = if ($platform.EndsWith('arm64')) { 'aarch64' } else { 'x86_64' }
        if ($platform.StartsWith('macos')) { $env:CONDA_OVERRIDE_ARCHSPEC = if ($platform.EndsWith('arm64')) { 'arm64' } else { 'x86_64' } }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('# feature' + "`tname`tversion`tsha256`turl")
        $lines.Add('# Reviewed explicit closure; micromamba 2.10.0; Linux glibc >=2.28/kernel >=4.18; macOS x64 >=13; macOS arm64 >=14.5.')
        if ($platform.StartsWith('linux')) {
            $lines.Add('# unavailable yazi-helper wl-clipboard: conda-forge has no published package; X11 xclip is included.')
        }
        $platformGroups = [ordered]@{}
        foreach ($feature in $groups.Keys) { $platformGroups[$feature] = $groups[$feature] }
        if ($platform.StartsWith('linux')) {
            $platformGroups['yazi-xclip'] = @('xclip=0.13')
            $platformGroups['yazi-glib'] = @('glib=2.90.1')
        }
        foreach ($feature in $platformGroups.Keys) {
            $specs = @($platformGroups[$feature])
            $prefix = Join-Path $work "solve-$platform-$feature"
            $resultFile = Join-Path $work "solve-$platform-$feature.json"
            $stderrFile = Join-Path $work "solve-$platform-$feature.stderr"
            $arguments = @('create', '--no-rc', '--dry-run', '--json', '--platform', $subdir,
                '--override-channels', '--repodata-ttl', '0', '-c', $channelUri, '--prefix', $prefix) + $specs
            $jsonText = (& $mamba @arguments 2> $stderrFile | Out-String)
            [IO.File]::WriteAllText($resultFile, $jsonText, [Text.UTF8Encoding]::new($false))
            if ($LASTEXITCODE -ne 0) { throw "Solver failed for $platform/$feature. See $resultFile and $stderrFile." }
            $result = $jsonText | ConvertFrom-Json
            if (-not $result.success -or -not $result.actions.LINK) { throw "No explicit solution for $platform/$feature." }
            foreach ($package in @($result.actions.LINK | Sort-Object name, version, build_string)) {
                if ($package.sha256 -notmatch '^[a-f0-9]{64}$') { throw "Missing SHA-256: $($package.name)" }
                if ($package.subdir -notin @($subdir, 'noarch')) { throw "Unexpected package subdir: $($package.subdir)" }
                $url = "https://conda.anaconda.org/conda-forge/$($package.subdir)/$($package.fn)"
                $lines.Add("$feature`t$($package.name)`t$($package.version)`t$($package.sha256)`t$url")
            }
            Write-Host "$platform/$feature : $(@($result.actions.LINK).Count) packages"
        }
        [IO.File]::WriteAllText((Join-Path $out "unix-$platform.tsv"), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    }
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
