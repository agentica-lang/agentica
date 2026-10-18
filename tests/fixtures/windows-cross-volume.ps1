param(
    [Parameter(Mandatory=$true)][ValidateSet('create', 'remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path
)
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^agentica-test-[0-9a-f]{32}$') {
    throw 'Unexpected VHD name'
}

if ($env:GITHUB_ACTIONS -ne 'true' -or
    $env:AGENTICA_ACTIONS_RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:AGENTICA_REMOVE_TEST_MODE -ne 'actions') {
    throw 'Cross-volume fixtures require confined hosted Actions scratch'
}
$root = [IO.Path]::GetFullPath($env:AGENTICA_REMOVE_TEST_SCRATCH).TrimEnd('\')
$directory = Get-Item -LiteralPath $Path
$full = $directory.FullName.TrimEnd('\')
if (-not $directory.PSIsContainer -or
    ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'VHD and mount point must be created under test scratch'
}
$vhd = Join-Path $full ($Name + '.vhdx')

function Invoke-DiskPart([string[]]$Lines) {
    $script = Join-Path $full ($Name + '.diskpart')
    try {
        Set-Content -LiteralPath $script -Value $Lines -Encoding Ascii
        $output = & diskpart.exe /s $script 2>&1
        if ($LASTEXITCODE -ne 0 -or ($output | Where-Object { $_ -match 'Virtual Disk Service error|DiskPart has encountered an error' })) {
            throw "diskpart failed: $($output -join [Environment]::NewLine)"
        }
    } finally {
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }
    return $output
}

if ($Action -eq 'create') {
    if (Test-Path -LiteralPath $vhd) { throw 'Refusing to reuse an existing VHD' }
    $letter = $null
    foreach ($candidate in [char[]](90..68 | ForEach-Object { [char]$_ })) {
        if (-not (Get-Volume -DriveLetter $candidate -ErrorAction SilentlyContinue)) {
            $letter = $candidate
            break
        }
    }
    if (-not $letter) { throw 'No free drive letter for the disposable VHD' }
    $label = 'agc' + $Name.Substring($Name.Length - 8)
    Invoke-DiskPart @(
        "create vdisk file=`"$vhd`" maximum=64 type=expandable",
        "select vdisk file=`"$vhd`"",
        'attach vdisk',
        'create partition primary',
        "format fs=ntfs quick label=$label",
        "assign letter=$letter"
    ) | Out-Null
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ($volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne $label) {
        throw 'The test VHD is not a fresh NTFS volume'
    }
    Write-Output "AGENTICA_DRIVE=$letter`:\"
} else {
    $mounted = Get-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue
    if ($mounted -and $mounted.Attached) {
        Invoke-DiskPart @("select vdisk file=`"$vhd`"", 'detach vdisk') | Out-Null
    }
    $mounted = Get-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue
    if ($mounted -and $mounted.Attached) { throw 'Test VHD remained attached' }
    if (Test-Path -LiteralPath $vhd) {
        $resolved = [IO.Path]::GetFullPath($vhd)
        if (-not $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to delete VHD outside test scratch'
        }
        Remove-Item -LiteralPath $resolved -Force
    }
    if (Test-Path -LiteralPath $vhd) { throw 'Test VHD cleanup failed' }
}
