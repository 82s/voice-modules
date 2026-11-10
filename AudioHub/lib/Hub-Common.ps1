#Requires -Version 5.1
<#
.SYNOPSIS
    Shared configuration, logging, and verification helpers for the Audio Hub.
.DESCRIPTION
    Dot-source this file at the top of every other Hub PS1 script:
        . "$PSScriptRoot\Hub-Common.ps1"
    Do NOT run this file directly.

    !! EDIT THE $Script:HubConfig SECTION BELOW BEFORE FIRST USE !!
#>

# ============================================================================
#  CONFIGURATION - EDIT BEFORE FIRST USE
# ============================================================================
$Script:HubConfig = @{

    # -- VB-Audio Matrix download --------------------------------------------
    #  Full URL = DownloadBaseUrl + ZipFilename
    DownloadBaseUrl           = 'https://download.vb-audio.com/Download_Mixer/'
    ZipFilename               = 'VBAudioMatrix_Setup_v2026.zip'
    InstallerVersion          = 'v2026'

    #  Exact installer EXE name inside the ZIP - NO wildcards.
    InstallerFilename         = 'VBAudioMatrixCoconut_Setup.exe'

    # Verified SHA-256 hash and Authenticode Signer CN derived from
    # official package VBAudioMatrix_Setup_v2026.zip:
    ExpectedZipSha256         = '0840CAB829C2A14DA3D79B643E97C9323FAD1E1EDD117EAA581A198B03AEF358'
    ExpectedInstallerSignerCN = 'BUREL VINCENT Entrepreneur individuel'

    # Only this exact domain is allowed for downloads - no wildcards.
    AllowedDownloadDomain     = 'download.vb-audio.com'

    # -- Process identification (exact names, no wildcards) ------------------
    MatrixProcessNames        = @(
        'VBAudioMatrixCoconut_x64'
        'VBAudioMatrix_x64'
        'VBAudioMatrix'
    )

    # -- Priority boost - applied only when the user opts in ----------------
    #  Valid values: Normal, AboveNormal, High
    DefaultPriority           = 'AboveNormal'

    # -- Timeouts -----------------------------------------------------------
    NetworkTimeoutSeconds     = 60
    ProcessStartWaitSeconds   = 15
    GracefulCloseWaitSeconds  = 5

    # -- Endpoint rename / disable maps -------------------------------------
    RenderPinNames = @{
        1 = 'Desktop Audio'
        2 = 'Voicechat Audio'
        3 = 'Media'
        4 = 'Browser'
        5 = 'Spotify'
    }
    CapturePinNames = @{
        1 = 'Voicechat Mic'
        2 = 'Discord Mic'
        3 = 'In-Game Mic'
        4 = 'OBS Mic'
        5 = 'Voice Changer'
    }

    # -- Compatibility ------------------------------------------------------
    # Allow launch of Ableton if signature is HashMismatch (common with patched DAW installations)
    AllowUnverifiedAbleton    = $true
}

# ============================================================================
#  COMPUTED PATHS  (relative to the repo root, one level above lib/)
# ============================================================================
$Script:RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:HubConfig['LogDirectory']    = Join-Path $Script:RepoRoot 'logs'
$Script:HubConfig['BackupDirectory'] = Join-Path $Script:RepoRoot 'backups'

# ============================================================================
#  EXIT CODES
# ============================================================================
$Script:ExitCodes = @{
    Success             = 0
    InvalidArgument     = 1
    ConfigNotSet        = 2
    DownloadFailed      = 3
    HashMismatch        = 4
    SignatureInvalid    = 5
    SignerMismatch      = 6
    RedirectBlocked     = 7
    FileNotFound        = 8
    ExeVerifyFailed     = 9
    InstallerFailed     = 10
    UserCancelled       = 11
    RegistryFailed      = 12
    BackupFailed        = 13
    RestoreFailed       = 14
    RollbackFailed      = 15
    XmlValidationFailed = 16
    TimeoutExpired      = 17
    ElevationRequired   = 18
    UnexpectedError     = 99
}

# ============================================================================
#  LOGGING
# ============================================================================
$Script:CurrentLogFile = $null

function Initialize-HubLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Component)

    $logDir = $Script:HubConfig.LogDirectory
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $Script:CurrentLogFile = Join-Path $logDir "${Component}_${ts}.log"
    Write-HubLog "=== Log started: $Component ===" -Level INFO
    return $Script:CurrentLogFile
}

function Write-HubLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION','VERIFY','BACKUP','ROLLBACK')]
        [string]$Level = 'INFO'
    )

    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    if ($Script:CurrentLogFile) {
        try   { Add-Content -LiteralPath $Script:CurrentLogFile -Value $line -ErrorAction Stop }
        catch { <# logging must never crash the script #> }
    }

    switch ($Level) {
        'ERROR'    { Write-Host "  [ERROR]    $Message" -ForegroundColor Red        }
        'WARN'     { Write-Host "  [WARN]     $Message" -ForegroundColor Yellow     }
        'ACTION'   { Write-Host "  [*]        $Message" -ForegroundColor Cyan       }
        'VERIFY'   { Write-Host "  [VERIFY]   $Message" -ForegroundColor Magenta    }
        'BACKUP'   { Write-Host "  [BACKUP]   $Message" -ForegroundColor DarkCyan   }
        'ROLLBACK' { Write-Host "  [ROLLBACK] $Message" -ForegroundColor DarkYellow }
        default    { Write-Host "  [i]        $Message" -ForegroundColor Gray       }
    }
}

# ============================================================================
#  CONFIGURATION VALIDATION
# ============================================================================
function Test-HubConfigReady {
    [CmdletBinding()]
    param()
    $issues = [System.Collections.Generic.List[string]]::new()

    if ($Script:HubConfig.ExpectedZipSha256 -like '*PLACEHOLDER*' -or [string]::IsNullOrWhiteSpace($Script:HubConfig.ExpectedZipSha256)) {
        $issues.Add('ExpectedZipSha256 is not configured - set it to the real SHA-256 hash of the ZIP.')
    }
    if ($Script:HubConfig.ExpectedInstallerSignerCN -like '*PLACEHOLDER*' -or [string]::IsNullOrWhiteSpace($Script:HubConfig.ExpectedInstallerSignerCN)) {
        $issues.Add('ExpectedInstallerSignerCN is not configured - set it to the signer CN from the installer certificate.')
    }
    return $issues
}

# ============================================================================
#  FILE-HASH VERIFICATION
# ============================================================================
function Test-HubFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-HubLog "Hash check: file not found - $FilePath" -Level ERROR
        return $false
    }

    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    Write-HubLog "SHA-256 actual  : $actual"       -Level VERIFY
    Write-HubLog "SHA-256 expected: $ExpectedHash" -Level VERIFY

    if ($actual -ne $ExpectedHash) {
        Write-HubLog 'SHA-256 MISMATCH - aborting.' -Level ERROR
        return $false
    }
    Write-HubLog 'SHA-256 verified OK.' -Level VERIFY
    return $true
}

# ============================================================================
#  AUTHENTICODE VERIFICATION
# ============================================================================
function Test-HubAuthenticode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ExpectedSignerCN
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-HubLog "Authenticode check: file not found - $FilePath" -Level ERROR
        return $false
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $FilePath
    Write-HubLog "Authenticode status : $($sig.Status)" -Level VERIFY

    if ($sig.Status -ne 'Valid') {
        Write-HubLog "Authenticode status is NOT Valid (got: $($sig.Status)) - aborting." -Level ERROR
        return $false
    }

    $subject = $sig.SignerCertificate.Subject
    Write-HubLog "Signer subject: $subject" -Level VERIFY

    $cn = ''
    if ($subject -match 'CN\s*=\s*"?([^",]+)"?') { $cn = $Matches[1].Trim() }

    if ($cn -ne $ExpectedSignerCN) {
        Write-HubLog "Signer CN MISMATCH - expected '$ExpectedSignerCN', got '$cn'." -Level ERROR
        return $false
    }

    Write-HubLog 'Authenticode + signer verified OK.' -Level VERIFY
    return $true
}

# ============================================================================
#  LOCAL EXECUTABLE PRE-LAUNCH CHECK
# ============================================================================
function Test-HubLocalExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Label = 'Executable',
        [switch]$AllowModified
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-HubLog "$Label not found: $FilePath" -Level ERROR
        return $false
    }

    $resolved = (Resolve-Path -LiteralPath $FilePath).Path

    # Must be on a local lettered drive (not UNC, not URL)
    if ($resolved -notmatch '^[A-Za-z]:\\') {
        Write-HubLog "$Label is not on a local drive: $resolved" -Level ERROR
        return $false
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $resolved
    if ($sig.Status -eq 'Valid') {
        Write-HubLog "$Label signature valid -- $($sig.SignerCertificate.Subject)" -Level VERIFY
        return $true
    }

    if ($AllowModified -or ($Label -like '*Ableton*' -and $Script:HubConfig.AllowUnverifiedAbleton)) {
        Write-HubLog "$Label signature status is $($sig.Status), but permitted by AllowUnverifiedAbleton configuration." -Level WARN
        Write-Host "  [WARN] $Label signature verification status: $($sig.Status)." -ForegroundColor Yellow
        Write-Host "         Proceeding based on AllowUnverifiedAbleton configuration." -ForegroundColor Yellow
        return $true
    }

    Write-HubLog "${Label}: signature verification failed (status: $($sig.Status)) -- rejecting execution." -Level ERROR
    return $false
}

function Test-HubIsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
#  USER CONFIRMATION HELPER
# ============================================================================
function Request-HubConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$DefaultNo
    )

    $hint   = if ($DefaultNo) { '[y/N]' } else { '[Y/n]' }
    $answer = Read-Host "$Prompt $hint"

    if ($DefaultNo) { return ($answer -match '^[Yy]$')    }
    else            { return ($answer -notmatch '^[Nn]$') }
}
