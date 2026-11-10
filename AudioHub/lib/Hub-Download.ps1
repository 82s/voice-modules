#Requires -Version 5.1
<#
.SYNOPSIS
    Secure download, verification, and installation of VB-Audio Matrix.
.DESCRIPTION
    * Downloads only from the configured HTTPS URL on vb-audio.com.
    * Rejects redirects that leave the allowed domain.
    * Uses a unique temporary directory.
    * Requires exact ZIP and installer filenames - never globs *Setup*.exe.
    * Verifies SHA-256 hash of the ZIP.
    * Verifies Authenticode status is Valid and signer CN matches config.
    * Displays full verification summary and requires explicit confirmation.
    * Reports each step (download, extract, hash, signature, installer, cleanup).
    * Fails closed on any mismatch.
    * Refuses to install while PLACEHOLDER values remain in Hub-Common.ps1.
    * Returns a failure exit code if the installer fails.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hub-Common.ps1')

$logFile = Initialize-HubLog -Component 'Download'

# -- Step tracking -----------------------------------------------------------
$downloadOk        = $false
$extractOk         = $false
$hashOk            = $false
$signatureOk       = $false
$installerExitCode = $null
$cleanupOk         = $false
$tempDir           = $null

function Show-DownloadSummary {
    Write-Host ''
    Write-Host '  +---------------------------------+' -ForegroundColor Cyan
    Write-Host '  |     DOWNLOAD STEP SUMMARY       |' -ForegroundColor Cyan
    Write-Host '  +---------------------------------+' -ForegroundColor Cyan

    $steps = @(
        @{ Name = 'Download';     Ok = $downloadOk   }
        @{ Name = 'Hash verify';  Ok = $hashOk       }
        @{ Name = 'Extract';      Ok = $extractOk    }
        @{ Name = 'Signature';    Ok = $signatureOk  }
    )
    foreach ($s in $steps) {
        $icon  = if ($s.Ok) { '[PASS]' } else { '[FAIL]' }
        $color = if ($s.Ok) { 'Green'  } else { 'Red'    }
        Write-Host "    $icon $($s.Name)" -ForegroundColor $color
    }
    if ($null -ne $installerExitCode) {
        $ok    = ($installerExitCode -eq 0)
        $icon  = if ($ok) { '[PASS]' } else { '[FAIL]' }
        $color = if ($ok) { 'Green'  } else { 'Red'    }
        Write-Host "    $icon Installer (exit $installerExitCode)" -ForegroundColor $color
    }
    $cIcon  = if ($cleanupOk) { '[PASS]' } else { '[WARN]' }
    $cColor = if ($cleanupOk) { 'Green'  } else { 'Yellow' }
    Write-Host "    $cIcon Cleanup" -ForegroundColor $cColor
    Write-Host "    Log : $logFile" -ForegroundColor Gray
    Write-Host ''
}

# -----------------------------------------------------------------------------
Write-Host ''
Write-Host '===============================================================================' -ForegroundColor Cyan
Write-Host '             SECURE DOWNLOAD AND INSTALLATION MANAGER'                          -ForegroundColor Cyan
Write-Host '===============================================================================' -ForegroundColor Cyan
Write-Host ''

# -- 0  Configuration gate ---------------------------------------------------
$cfgIssues = Test-HubConfigReady
if ($cfgIssues.Count -gt 0) {
    Write-HubLog 'INSTALLATION BLOCKED - configuration incomplete.' -Level ERROR
    foreach ($i in $cfgIssues) { Write-HubLog "  -> $i" -Level ERROR }
    Write-HubLog 'Edit lib\Hub-Common.ps1 and replace PLACEHOLDER values before installing.' -Level ERROR
    Show-DownloadSummary
    exit $Script:ExitCodes.ConfigNotSet
}

# -- 1  Build and validate URL -----------------------------------------------
$downloadUrl = $Script:HubConfig.DownloadBaseUrl.TrimEnd('/') + '/' + $Script:HubConfig.ZipFilename
$uri = [System.Uri]::new($downloadUrl)

if ($uri.Scheme -ne 'https') {
    Write-HubLog "URL scheme '$($uri.Scheme)' rejected - only HTTPS is allowed." -Level ERROR
    exit $Script:ExitCodes.DownloadFailed
}
if ($uri.Host -ne $Script:HubConfig.AllowedDownloadDomain) {
    Write-HubLog "URL domain '$($uri.Host)' rejected (allowed: $($Script:HubConfig.AllowedDownloadDomain))." -Level ERROR
    exit $Script:ExitCodes.RedirectBlocked
}
Write-HubLog "URL validated: $downloadUrl" -Level ACTION

# -- 2  Unique temp directory ------------------------------------------------
$uniqueId = [System.Guid]::NewGuid().ToString('N')
$tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) "AudioHub_$uniqueId"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-HubLog "Temp directory: $tempDir" -Level ACTION

$zipPath = Join-Path $tempDir $Script:HubConfig.ZipFilename

try {
    # -- 3  Check for verified local installer before downloading ------------
    $localCandidates = @(
        (Join-Path $Script:RepoRoot "things\$($Script:HubConfig.ZipFilename)"),
        (Join-Path $Script:RepoRoot "installers\$($Script:HubConfig.ZipFilename)"),
        (Join-Path $Script:RepoRoot $Script:HubConfig.ZipFilename)
    )

    $usedLocal = $false
    foreach ($cand in $localCandidates) {
        if (Test-Path -LiteralPath $cand) {
            Write-HubLog "Found local installer candidate: $cand" -Level INFO
            Write-Host "  [*] Checking local installer package: $cand..." -ForegroundColor Cyan
            if (Test-HubFileHash -FilePath $cand -ExpectedHash $Script:HubConfig.ExpectedZipSha256) {
                Copy-Item -LiteralPath $cand -Destination $zipPath -Force
                $downloadOk = $true
                $usedLocal  = $true
                Write-HubLog "Using verified local installer: $cand" -Level ACTION
                Write-Host '  [+] Verified local installer package ready.' -ForegroundColor Green
                break
            } else {
                Write-HubLog 'Local installer hash did not match. Falling back to web download.' -Level WARN
            }
        }
    }

    if (-not $usedLocal) {
        # -- Download with redirect checking ----------------------------------
        Write-HubLog "Downloading from $downloadUrl..." -Level ACTION
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $currentUri    = $uri
        $maxRedirects  = 5
        $redirectCount = 0
        $response      = $null

        while ($true) {
            $request = [System.Net.HttpWebRequest]::Create($currentUri)
            $request.AllowAutoRedirect = $false
            $request.Timeout           = $Script:HubConfig.NetworkTimeoutSeconds * 1000
            $request.Method            = 'GET'

        try {
            $response = $request.GetResponse()
        } catch [System.Net.WebException] {
            $webResp = $_.Exception.Response
            if ($webResp -and [int]$webResp.StatusCode -ge 300 -and [int]$webResp.StatusCode -lt 400) {
                $response = $webResp
            } else { throw }
        }

        $code = [int]$response.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $redirectCount++
            if ($redirectCount -gt $maxRedirects) {
                $response.Close()
                Write-HubLog "Too many redirects ($redirectCount)." -Level ERROR
                exit $Script:ExitCodes.RedirectBlocked
            }
            $location = $response.Headers['Location']
            $response.Close()

            if ([string]::IsNullOrWhiteSpace($location)) {
                Write-HubLog 'Redirect with empty Location header.' -Level ERROR
                exit $Script:ExitCodes.RedirectBlocked
            }
            $nextUri = [System.Uri]::new($currentUri, $location)

            if ($nextUri.Host -ne $Script:HubConfig.AllowedDownloadDomain) {
                Write-HubLog "Redirect to disallowed domain: $($nextUri.Host)" -Level ERROR
                exit $Script:ExitCodes.RedirectBlocked
            }
            if ($nextUri.Scheme -ne 'https') {
                Write-HubLog "Redirect to non-HTTPS: $($nextUri.Scheme)" -Level ERROR
                exit $Script:ExitCodes.RedirectBlocked
            }
            Write-HubLog "Following redirect #$redirectCount -> $nextUri" -Level ACTION
            $currentUri = $nextUri
            continue
        }
        break   # 2xx - success
    }

    # Save response body to file
    $respStream = $response.GetResponseStream()
    try {
        $fs = [System.IO.File]::Create($zipPath)
        try     { $respStream.CopyTo($fs) }
        finally { $fs.Close() }
    } finally {
        $respStream.Close()
        $response.Close()
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-HubLog 'Download produced no file.' -Level ERROR
        exit $Script:ExitCodes.DownloadFailed
    }

    $downloadOk = $true
    Write-HubLog "Download complete: $zipPath" -Level ACTION

    # -- 4  Verify ZIP hash --------------------------------------------------
        Write-HubLog 'Verifying ZIP SHA-256...' -Level ACTION
        $hashOk = Test-HubFileHash -FilePath $zipPath -ExpectedHash $Script:HubConfig.ExpectedZipSha256
        if (-not $hashOk) {
            Write-HubLog 'ZIP hash verification FAILED.' -Level ERROR
            exit $Script:ExitCodes.HashMismatch
        }
    } else {
        $hashOk = $true
    }

    # -- 5  Extract ----------------------------------------------------------
    Write-HubLog 'Extracting ZIP...' -Level ACTION
    $extractDir = Join-Path $tempDir 'extracted'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $extractOk = $true
    Write-HubLog "Extracted to: $extractDir" -Level ACTION

    # -- 6  Find EXACT installer filename - never glob *Setup*.exe -----------
    $expectedName = $Script:HubConfig.InstallerFilename

    $candidates = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
                  Where-Object { $_.Name -eq $expectedName }

    if ($candidates.Count -eq 0) {
        Write-HubLog "Expected installer '$expectedName' NOT found in ZIP." -Level ERROR
        Write-HubLog 'ZIP contents:' -Level INFO
        Get-ChildItem -LiteralPath $extractDir -Recurse -File |
            ForEach-Object { Write-HubLog "  $($_.FullName)" -Level INFO }
        exit $Script:ExitCodes.FileNotFound
    }
    if ($candidates.Count -gt 1) {
        Write-HubLog "Multiple files named '$expectedName' - ambiguous, aborting." -Level ERROR
        exit $Script:ExitCodes.FileNotFound
    }

    $installerPath = $candidates[0].FullName

    # Double-check filename
    if ([System.IO.Path]::GetFileName($installerPath) -ne $expectedName) {
        Write-HubLog 'Installer filename sanity check failed.' -Level ERROR
        exit $Script:ExitCodes.FileNotFound
    }
    Write-HubLog "Installer located: $installerPath" -Level ACTION

    # -- 7  Authenticode + signer --------------------------------------------
    Write-HubLog 'Verifying installer Authenticode signature...' -Level ACTION
    $signatureOk = Test-HubAuthenticode -FilePath $installerPath `
                       -ExpectedSignerCN $Script:HubConfig.ExpectedInstallerSignerCN
    if (-not $signatureOk) {
        Write-HubLog 'Installer signature / signer verification FAILED.' -Level ERROR
        exit $Script:ExitCodes.SignerMismatch
    }

    # -- 8  Display summary and require confirmation -------------------------
    $instHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    $instSig  = Get-AuthenticodeSignature -LiteralPath $installerPath
    Write-HubLog "Installer SHA-256: $instHash" -Level VERIFY

    Write-Host ''
    Write-Host '  +----------------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |           INSTALLER VERIFICATION SUMMARY                 |' -ForegroundColor Green
    Write-Host '  +----------------------------------------------------------+' -ForegroundColor Green
    Write-Host "    URL       : $downloadUrl"                           -ForegroundColor White
    Write-Host "    Version   : $($Script:HubConfig.InstallerVersion)"  -ForegroundColor White
    Write-Host "    ZIP File  : $($Script:HubConfig.ZipFilename)"       -ForegroundColor White
    Write-Host "    ZIP Hash  : VERIFIED"                               -ForegroundColor Green
    Write-Host "    Installer : $expectedName"                          -ForegroundColor White
    Write-Host "    Inst Hash : $instHash"                              -ForegroundColor White
    Write-Host "    Signer    : $($instSig.SignerCertificate.Subject)"  -ForegroundColor White
    Write-Host "    Signature : VERIFIED"                               -ForegroundColor Green
    Write-Host ''

    if (-not (Request-HubConfirmation -Prompt 'Run this installer now?' -DefaultNo)) {
        Write-HubLog 'User declined installer.' -Level ACTION
        Write-Host '  Installation cancelled by user.' -ForegroundColor Yellow
        exit $Script:ExitCodes.UserCancelled
    }

    # -- 9  Run installer ---------------------------------------------------
    Write-HubLog "Launching installer: $installerPath" -Level ACTION
    $proc = Start-Process -FilePath $installerPath -Wait -PassThru
    $installerExitCode = $proc.ExitCode
    Write-HubLog "Installer exit code: $installerExitCode" -Level ACTION

    if ($installerExitCode -ne 0) {
        Write-HubLog "Installer failed with non-zero exit code: $installerExitCode" -Level ERROR
        Write-Host "  [FAIL] Installer failed with exit code $installerExitCode." -ForegroundColor Red
        exit $Script:ExitCodes.InstallerFailed
    } else {
        Write-Host '  [OK] Installer completed successfully.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  [!] A computer restart is recommended after installing audio drivers.' -ForegroundColor Yellow

} catch {
    Write-HubLog "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-HubLog "Stack: $($_.ScriptStackTrace)" -Level ERROR
    Show-DownloadSummary
    exit $Script:ExitCodes.UnexpectedError
} finally {
    # -- 10  Cleanup ---------------------------------------------------------
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
        try {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction Stop
            $cleanupOk = $true
            Write-HubLog "Temp directory removed: $tempDir" -Level ACTION
        } catch {
            Write-HubLog "Cleanup failed: $($_.Exception.Message)" -Level WARN
        }
    } else {
        $cleanupOk = $true
    }
    Show-DownloadSummary
}
