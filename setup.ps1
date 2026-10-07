# Windows PowerShell 5.1+. Run setup.bat or .\setup.ps1.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UvVersion = '0.12.11'
$Root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
# Normalize mapped drives so Python always uses the network share's real path.
if ($Root -match '^[A-Za-z]:\\') {
    $drive = Get-PSDrive -Name $Root.Substring(0,1) -PSProvider FileSystem
    $share = $drive | Select-Object -ExpandProperty DisplayRoot -ErrorAction SilentlyContinue
    if ($share -and $share.StartsWith('\\')) {
        $Root = $share.TrimEnd('\') + $Root.Substring(2)
    }
}

$BinDir = Join-Path $Root 'bin'
$PythonDir = Join-Path $Root 'python'
$VenvDir = Join-Path $Root '.venv'
$CacheDir = Join-Path $Root '.cache'
$GeneratedDirs = @($BinDir, $PythonDir, $VenvDir, $CacheDir)
$Uv = Join-Path $BinDir 'uv.exe'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'

function Remove-Entry([IO.FileSystemInfo]$Entry) {
    # Unlink junctions/symlinks themselves, without ever visiting their targets.
    if ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($Entry.PSIsContainer) { [IO.Directory]::Delete($Entry.FullName) }
        else { [IO.File]::Delete($Entry.FullName) }
        return
    }
    if ($Entry.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Entry.FullName -Force) {
            Remove-Entry $child
        }
    }
    Remove-Item -LiteralPath $Entry.FullName -Force
}

function Remove-GeneratedDirectories {
    foreach ($path in $GeneratedDirs) {
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ((Split-Path $full) -ne $Root -or
            (Split-Path $full -Leaf) -notin @('bin', 'python', '.venv', '.cache')) {
            throw "Refusing to delete a path outside the generated folders: $full"
        }
        $entry = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($entry) { Remove-Entry $entry }
    }
}

function Invoke-Uv([string[]]$Arguments) {
    & $Uv @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "uv failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
}

function Install-Uv {
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    $target = switch ($architecture) {
        'AMD64' { 'x86_64-pc-windows-msvc' }
        'ARM64' { 'aarch64-pc-windows-msvc' }
        default { throw 'Setup requires 64-bit Windows (x64 or ARM64).' }
    }
    New-Item -ItemType Directory -Path $BinDir, $CacheDir | Out-Null
    $archive = Join-Path $CacheDir 'uv.zip'
    $url = "https://releases.astral.sh/github/uv/releases/download/$UvVersion/uv-$target.zip"

    Write-Host "Downloading uv $UvVersion..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 120
    Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile "$archive.sha256" -TimeoutSec 120
    $expected = ((Get-Content -LiteralPath "$archive.sha256" -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
        throw 'The uv download failed SHA-256 verification.'
    }

    $unpacked = Join-Path $CacheDir 'uv-unpacked'
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
    $executables = @(Get-ChildItem -LiteralPath $unpacked -Filter uv.exe -Recurse -File)
    if ($executables.Count -ne 1) { throw 'Expected exactly one uv.exe in the download.' }
    Copy-Item -LiteralPath $executables[0].FullName -Destination $Uv
}

function Install-Python {
    Write-Host "Installing local Python $PythonVersion..."
    # In PowerShell 5.1 native stderr becomes error records. Check uv's exit code explicitly.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Uv python install $PythonVersion --no-bin --no-registry 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    foreach ($line in $output) { Write-Host "$line" }

    # uv can finish extracting Python but fail to create its junction on a network share.
    $linkError = 'Failed to create Python minor version link directory|Missing expected target directory for Python minor version link at '
    if ($code -ne 0 -and ($output | Out-String) -notmatch $linkError) {
        throw "Python installation failed (exit $code)."
    }

    # Select the actual installation, never the optional minor-version junction.
    $pattern = '^cpython-3\.\d+\.\d+-windows-(x86_64|aarch64)-none$'
    $installations = @(Get-ChildItem -LiteralPath $PythonDir -Directory |
        Where-Object { $_.Name -match $pattern -and
            !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    if ($installations.Count -ne 1) { throw 'Expected one downloaded Python installation.' }
    $python = Join-Path $installations[0].FullName 'python.exe'
    # Verify the downloaded executable and standard library before creating the environment.
    $check = @'
import pathlib, ssl, sqlite3, sys, venv
assert pathlib.Path(sys.executable).resolve() == pathlib.Path(sys.argv[1]).resolve()
assert pathlib.Path(sys.base_prefix).resolve() == pathlib.Path(sys.argv[1]).parent.resolve()
requested = tuple(map(int, sys.argv[2].split('.')))
assert sys.version_info[:len(requested)] == requested
'@
    $check | & $python -I -B - $python $PythonVersion
    if ($LASTEXITCODE -ne 0) { throw 'The downloaded Python failed verification.' }
    if ($code -ne 0) { Write-Host "Version link unavailable; using verified Python: $python" }
    return $python
}

try {
    $PythonVersion = '3.13'
    $versionFile = Join-Path $Root '.python-version'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $PythonVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    if ($PythonVersion -notmatch '^3\.\d+(\.\d+)?$') {
        throw '.python-version must contain a version such as 3.13 or 3.13.15.'
    }

    $existing = @($GeneratedDirs | Where-Object { Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue })
    if ($existing.Count -gt 0) {
        Write-Host 'Reinstalling will delete and recreate these folders:'
        $GeneratedDirs | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Your scripts, setup files, and project configuration will be kept.'
        if ((Read-Host 'Reinstall? [y/N]') -notmatch '^(y|yes)$') {
            Write-Host 'Cancelled. No files were changed.'
            exit 2
        }
    }

    # Keep uv's Python, environment, and cache local; ignore inherited uv/Python overrides.
    Get-ChildItem Env: | Where-Object Name -like 'UV_*' | ForEach-Object {
        Remove-Item -LiteralPath ("Env:" + $_.Name)
    }
    Remove-Item Env:VIRTUAL_ENV, Env:CONDA_PREFIX, Env:PYTHONHOME, Env:PYTHONPATH -ErrorAction SilentlyContinue
    $env:UV_PYTHON_INSTALL_DIR = $PythonDir
    $env:UV_CACHE_DIR = Join-Path $CacheDir 'uv'
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    $env:UV_NO_CONFIG = '1'

    Remove-GeneratedDirectories
    Install-Uv
    $basePython = Install-Python
    Invoke-Uv @('venv', $VenvDir, '--python', $basePython, '--no-python-downloads')
    Write-Host "Setup complete. Python: $VenvPython"
    Write-Host 'Run a script with: ".venv\Scripts\python.exe" scripts\my_script.py'
} catch {
    [Console]::Error.WriteLine("Setup failed: " + $_.Exception.Message)
    exit 1
}
