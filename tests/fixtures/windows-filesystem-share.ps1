param(
    [Parameter(Mandatory=$true)][ValidateSet('create', 'remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path
)
$ErrorActionPreference = 'Stop'

# Only publish this test's fresh directory on an ephemeral hosted runner.
if ($env:GITHUB_ACTIONS -ne 'true' -or
    $env:AGENTICA_ACTIONS_RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:AGENTICA_REMOVE_TEST_MODE -ne 'actions') {
    throw 'SMB fixtures require confined hosted Actions scratch'
}
if ($Name -notmatch '^agentica-test-[0-9a-f]{32}$') {
    throw 'Unexpected share name'
}
$root = [IO.Path]::GetFullPath($env:AGENTICA_REMOVE_TEST_SCRATCH).TrimEnd('\')
$directory = Get-Item -LiteralPath $Path
$full = $directory.FullName.TrimEnd('\')
if (-not $directory.PSIsContainer -or
    ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Share path must be a real directory below test scratch'
}

if ($Action -eq 'create') {
    if (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue) {
        throw 'Refusing to reuse an existing share'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    New-SmbShare -Name $Name -Path $full -FullAccess $identity `
        -CachingMode None -FolderEnumerationMode AccessBased | Out-Null
    $share = Get-SmbShare -Name $Name
    if ($share.Path -ne $full) {
        throw 'Created share does not point at the test directory'
    }
} else {
    $share = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($share) {
        if ($share.Path -ne $full) {
            throw 'Refusing to remove a share with an unexpected path'
        }
        Remove-SmbShare -Name $Name -Force -Confirm:$false
    }
    if (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue) {
        throw 'Test share cleanup failed'
    }
}
