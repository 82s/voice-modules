#Requires -Version 5.1
<#
.SYNOPSIS
    Safe VB-Audio Matrix endpoint manager: Preview, Apply (with backup + rollback),
    and Restore from backup.
.DESCRIPTION
    Modes:
      Menu            Unelevated sub-menu (default when launched from bat).
      Preview         Read-only scan and display proposed changes.
      ApplyElevated   Runs elevated; validates every operation against a fresh scan
                      of verified VB-Audio Matrix endpoints, creates a backup,
                      applies changes with per-operation SDDL save/restore, rolls
                      back on failure, and offers an audio service restart.
      RestoreElevated Runs elevated; validates backup entries against live endpoints,
                      restores values and original security descriptors, and fails
                      if restoring ownership/permissions fails.

    Security-descriptor handling:
      Before each write the original SDDL is captured. If capture fails, the
      operation aborts immediately. Ownership is taken temporarily, a minimal
      SetValue rule is added, the value is written, and the original SDDL is
      restored in a finally block. Any SDDL restoration failure is reported
      and treated as an operation failure.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Preview','ApplyElevated','RestoreElevated')]
    [string]$Mode = 'Menu',

    [string]$PlanFile   = '',
    [string]$BackupFile = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hub-Common.ps1')

$logFile = Initialize-HubLog -Component "Endpoints_$Mode"

# ============================================================================
#  C# TYPE - SAFE REGISTRY HELPER (SDDL save / temporary elevation / restore)
# ============================================================================
$csharpCode = @'
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;

public static class SafeRegHelper
{
    // -- P/Invoke for privilege management -------------------------------
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(
        IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool LookupPrivilegeValue(
        string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, uint BufferLength,
        IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

    private static void EnablePrivileges()
    {
        IntPtr token;
        if (!OpenProcessToken(
                System.Diagnostics.Process.GetCurrentProcess().Handle,
                0x0020 | 0x0008, out token))
            return;

        foreach (string priv in new[] {
            "SeTakeOwnershipPrivilege",
            "SeRestorePrivilege",
            "SeBackupPrivilege" })
        {
            LUID luid;
            if (LookupPrivilegeValue(null, priv, out luid))
            {
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Luid = luid;
                tp.Attributes = 2; // SE_PRIVILEGE_ENABLED
                AdjustTokenPrivileges(token, false, ref tp, 0,
                    IntPtr.Zero, IntPtr.Zero);
            }
        }
    }

    // -- Read SDDL (Owner + DACL) ----------------------------------------
    public static string GetSddl(string relKey)
    {
        try
        {
            EnablePrivileges();
            using (RegistryKey rk = Registry.LocalMachine.OpenSubKey(
                relKey,
                RegistryKeyPermissionCheck.ReadSubTree,
                RegistryRights.ReadPermissions))
            {
                if (rk == null) return null;
                return rk.GetAccessControl(
                    AccessControlSections.Owner | AccessControlSections.Access)
                    .GetSecurityDescriptorSddlForm(
                        AccessControlSections.Owner | AccessControlSections.Access);
            }
        }
        catch { return null; }
    }

    // -- Restore SDDL (returns null on success, error message on failure) --
    public static string RestoreSddl(string relKey, string sddl)
    {
        if (string.IsNullOrEmpty(sddl))
            return "SDDL string is empty or null for " + relKey;
        try
        {
            EnablePrivileges();
            using (RegistryKey rk = Registry.LocalMachine.OpenSubKey(
                relKey,
                RegistryKeyPermissionCheck.ReadWriteSubTree,
                RegistryRights.TakeOwnership | RegistryRights.ChangePermissions))
            {
                if (rk == null)
                    return "Cannot open key to restore SDDL: " + relKey;
                RegistrySecurity sec = new RegistrySecurity();
                sec.SetSecurityDescriptorSddlForm(sddl,
                    AccessControlSections.Owner | AccessControlSections.Access);
                rk.SetAccessControl(sec);
                return null;
            }
        }
        catch (Exception ex)
        {
            return "Failed to restore SDDL for " + relKey + ": " + ex.Message;
        }
    }

    // -- Write a single value with SDDL save/restore ---------------------
    //  Returns null on success, or an error message string on failure.
    public static string WriteValueSafe(
        string relKey, string valueName,
        object value,  RegistryValueKind kind)
    {
        EnablePrivileges();

        // 1. Capture original SDDL - MUST NOT PROCEED IF CAPTURE FAILS
        string origSddl = GetSddl(relKey);
        if (string.IsNullOrEmpty(origSddl))
        {
            return "Failed to capture original security descriptor for: " + relKey;
        }

        string writeError = null;
        try
        {
            SecurityIdentifier adminSid =
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);

            // 2. Take ownership temporarily
            using (RegistryKey rk = Registry.LocalMachine.OpenSubKey(
                relKey,
                RegistryKeyPermissionCheck.ReadWriteSubTree,
                RegistryRights.TakeOwnership))
            {
                if (rk == null) return "Cannot open key for TakeOwnership: " + relKey;
                RegistrySecurity sec = new RegistrySecurity();
                sec.SetOwner(adminSid);
                rk.SetAccessControl(sec);
            }

            // 3. Add minimal temporary write access
            using (RegistryKey rk = Registry.LocalMachine.OpenSubKey(
                relKey,
                RegistryKeyPermissionCheck.ReadWriteSubTree,
                RegistryRights.ChangePermissions | RegistryRights.ReadPermissions))
            {
                if (rk == null) return "Cannot open key for ChangePermissions: " + relKey;
                RegistrySecurity sec = rk.GetAccessControl();
                sec.AddAccessRule(new RegistryAccessRule(
                    adminSid,
                    RegistryRights.SetValue | RegistryRights.QueryValues,
                    InheritanceFlags.None,
                    PropagationFlags.None,
                    AccessControlType.Allow));
                rk.SetAccessControl(sec);
            }

            // 4. Write value
            using (RegistryKey rk = Registry.LocalMachine.OpenSubKey(
                relKey,
                RegistryKeyPermissionCheck.ReadWriteSubTree,
                RegistryRights.SetValue | RegistryRights.QueryValues))
            {
                if (rk == null) return "Cannot open key for writing: " + relKey;
                rk.SetValue(valueName, value, kind);
            }
        }
        catch (Exception ex)
        {
            writeError = "Write error on " + relKey + ": " + ex.Message;
        }
        finally
        {
            // 5. ALWAYS restore original SDDL - never swallow error!
            string restoreError = RestoreSddl(relKey, origSddl);
            if (!string.IsNullOrEmpty(restoreError))
            {
                if (string.IsNullOrEmpty(writeError))
                    writeError = restoreError;
                else
                    writeError = writeError + " AND " + restoreError;
            }
        }

        return writeError;
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'SafeRegHelper').Type) {
    Add-Type -TypeDefinition $csharpCode
}

# ============================================================================
#  CONSTANTS
# ============================================================================
$FriendlyNameProp = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$PinIdProp        = '{233164c8-1b2c-4c7d-bc68-b671687a2567},1'
$DeviceStateActive   = 1
$DeviceStateDisabled = 268435458   # 0x10000002

# ============================================================================
#  SCAN VB-AUDIO MATRIX ENDPOINTS
# ============================================================================
function Get-VBMatrixEndpoints {
    [CmdletBinding()]
    param()

    $results = [System.Collections.Generic.List[psobject]]::new()

    foreach ($direction in @('Render','Capture')) {
        $basePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$direction"
        if (-not (Test-Path -LiteralPath $basePath)) { continue }

        $pinPattern = if ($direction -eq 'Render') { 'vbmatrix.*_out(\d+)' }
                      else                          { 'vbmatrix.*_in(\d+)'  }

        $nameMap    = if ($direction -eq 'Render') { $Script:HubConfig.RenderPinNames }
                      else                          { $Script:HubConfig.CapturePinNames }

        Get-ChildItem -LiteralPath $basePath | ForEach-Object {
            $guidKey  = $_.PSChildName
            $propPath = Join-Path $_.PSPath 'Properties'
            if (-not (Test-Path -LiteralPath $propPath)) { return }

            $props = Get-ItemProperty -Path $propPath -ErrorAction SilentlyContinue
            $pin   = $props.$PinIdProp

            if ($pin -and $pin -match $pinPattern) {
                $pinNum       = [int]$Matches[1]
                $currentName  = $props.$FriendlyNameProp
                $currentState = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DeviceState

                $relBase = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$direction\$guidKey"
                $relProp = "$relBase\Properties"

                $targetName  = $nameMap[[int]$pinNum]
                $action      = 'Skip'
                $targetState = $currentState

                if ($pinNum -ge 6) {
                    # High-numbered pins: propose disable (never auto-apply)
                    if (($currentState -band 2) -eq 0) {
                        $action      = 'Disable'
                        $targetState = $DeviceStateDisabled
                    }
                } elseif ($targetName) {
                    $needRename = ($currentName -ne $targetName)
                    $needEnable = (($currentState -band 2) -ne 0)

                    if ($needRename -and $needEnable) { $action = 'RenameAndEnable'; $targetState = $DeviceStateActive }
                    elseif ($needRename)              { $action = 'Rename' }
                    elseif ($needEnable)              { $action = 'Enable'; $targetState = $DeviceStateActive }
                }

                $results.Add([pscustomobject]@{
                    Direction    = $direction
                    PinNumber    = $pinNum
                    GuidKey      = $guidKey
                    BaseKeyPath  = $relBase
                    PropKeyPath  = $relProp
                    CurrentName  = $currentName
                    TargetName   = if ($targetName) { $targetName } else { $currentName }
                    CurrentState = $currentState
                    TargetState  = $targetState
                    Action       = $action
                    PinId        = $pin
                })
            }
        }
    }

    return $results
}

# ============================================================================
#  PREVIEW
# ============================================================================
function Show-EndpointPreview {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '          ENDPOINT PREVIEW - No changes will be made'                            -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    $endpoints = Get-VBMatrixEndpoints
    if ($endpoints.Count -eq 0) {
        Write-Host '  No VB-Audio Matrix endpoints found.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Troubleshooting:' -ForegroundColor Cyan
        Write-Host '    1. Have you restarted your PC after installing VB-Audio Matrix?' -ForegroundColor White
        Write-Host '       Windows requires a PC reboot for virtual audio drivers to register.' -ForegroundColor Gray
        Write-Host '    2. Is VB-Audio Matrix installed? Check Option 5 in audio hub.bat.' -ForegroundColor Gray
        Write-Host ''
        return $endpoints
    }

    foreach ($ep in $endpoints | Sort-Object Direction, PinNumber) {
        $label = "$($ep.Direction) Pin $($ep.PinNumber)"
        switch ($ep.Action) {
            'Skip' {
                Write-Host "  [--] $label : '$($ep.CurrentName)' - no change needed" -ForegroundColor DarkGray
            }
            'Rename' {
                Write-Host "  [>>] $label : RENAME '$($ep.CurrentName)' -> '$($ep.TargetName)'" -ForegroundColor Green
            }
            'Enable' {
                Write-Host "  [>>] $label : ENABLE '$($ep.CurrentName)'" -ForegroundColor Green
            }
            'RenameAndEnable' {
                Write-Host "  [>>] $label : RENAME '$($ep.CurrentName)' -> '$($ep.TargetName)' + ENABLE" -ForegroundColor Green
            }
            'Disable' {
                Write-Host "  [!!] $label : DISABLE '$($ep.CurrentName)' (requires explicit confirmation)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''
    return $endpoints
}

# ============================================================================
#  BACKUP
# ============================================================================
function Export-EndpointBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.Generic.List[psobject]]$Endpoints)

    $backupDir = $Script:HubConfig.BackupDirectory
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $ts   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $path = Join-Path $backupDir "endpoint_backup_$ts.json"

    $entries = foreach ($ep in $Endpoints) {
        [pscustomobject]@{
            Direction    = $ep.Direction
            PinNumber    = $ep.PinNumber
            GuidKey      = $ep.GuidKey
            BaseKeyPath  = $ep.BaseKeyPath
            PropKeyPath  = $ep.PropKeyPath
            FriendlyName = $ep.CurrentName
            DeviceState  = $ep.CurrentState
            BaseSddl     = [SafeRegHelper]::GetSddl($ep.BaseKeyPath)
            PropSddl     = [SafeRegHelper]::GetSddl($ep.PropKeyPath)
        }
    }

    $backup = [pscustomobject]@{
        Timestamp = (Get-Date -Format 'o')
        Version   = 1
        Entries   = @($entries)
    }

    $backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-HubLog "Backup saved: $path" -Level BACKUP
    Write-Host "  [BACKUP] $path" -ForegroundColor DarkCyan
    return $path
}

# ============================================================================
#  APPLY (runs elevated)
# ============================================================================
function Invoke-EndpointApply {
    [CmdletBinding()]
    param()

    if (-not $PlanFile -or -not (Test-Path -LiteralPath $PlanFile)) {
        Write-HubLog "Plan file not found: $PlanFile" -Level ERROR
        exit $Script:ExitCodes.InvalidArgument
    }

    $plan = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json

    # Fresh scan of verified endpoints - do NOT trust paths or keys from editable JSON
    Write-HubLog 'Performing live endpoint scan to validate plan...' -Level ACTION
    $currentEndpoints = Get-VBMatrixEndpoints
    if ($currentEndpoints.Count -eq 0) {
        Write-HubLog 'No verified VB-Audio Matrix endpoints found during live scan.' -Level ERROR
        Write-Host '  [FAIL] No verified VB-Audio Matrix endpoints found on this machine.' -ForegroundColor Red
        exit $Script:ExitCodes.RegistryFailed
    }

    # Validate every operation against the verified scan
    $validatedOps = [System.Collections.Generic.List[psobject]]::new()
    foreach ($op in $plan.Operations) {
        if ($op.GuidKey -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') {
            Write-HubLog "Rejected operation: Malformed GuidKey '$($op.GuidKey)'" -Level ERROR
            exit $Script:ExitCodes.InvalidArgument
        }

        $matched = $currentEndpoints | Where-Object {
            $_.GuidKey -eq $op.GuidKey -and
            $_.Direction -eq $op.Direction -and
            $_.PinNumber -eq [int]$op.PinNumber
        } | Select-Object -First 1

        if (-not $matched) {
            Write-HubLog "Rejected operation: GuidKey $($op.GuidKey) is not a verified VB-Audio Matrix endpoint." -Level ERROR
            exit $Script:ExitCodes.InvalidArgument
        }

        # Reconstruct paths strictly from verified live scan
        $safeBaseKey = $matched.BaseKeyPath
        $safePropKey = $matched.PropKeyPath

        if ($op.Action -notin @('Rename', 'Enable', 'RenameAndEnable', 'Disable')) {
            Write-HubLog "Rejected operation: Invalid Action '$($op.Action)'" -Level ERROR
            exit $Script:ExitCodes.InvalidArgument
        }

        $safeTargetName = $matched.CurrentName
        if ($op.Action -in @('Rename', 'RenameAndEnable')) {
            $nameMap = if ($matched.Direction -eq 'Render') { $Script:HubConfig.RenderPinNames } else { $Script:HubConfig.CapturePinNames }
            $expectedName = $nameMap[[int]$matched.PinNumber]
            if (-not $expectedName -or $op.TargetName -ne $expectedName) {
                Write-HubLog "Rejected operation: TargetName '$($op.TargetName)' does not match configured name '$expectedName' for pin $($matched.PinNumber)" -Level ERROR
                exit $Script:ExitCodes.InvalidArgument
            }
            $safeTargetName = $expectedName
        }

        $safeTargetState = $matched.CurrentState
        if ($op.Action -eq 'Disable') {
            $safeTargetState = $DeviceStateDisabled
        } elseif ($op.Action -in @('Enable', 'RenameAndEnable')) {
            $safeTargetState = $DeviceStateActive
        }

        $validatedOps.Add([pscustomobject]@{
            Direction   = $matched.Direction
            PinNumber   = $matched.PinNumber
            GuidKey     = $matched.GuidKey
            BaseKeyPath = $safeBaseKey
            PropKeyPath = $safePropKey
            Action      = $op.Action
            TargetName  = $safeTargetName
            TargetState = $safeTargetState
        })
    }

    # Build backup from current live state before making any changes
    Write-HubLog 'Creating pre-apply backup...' -Level BACKUP
    $backupPath = Export-EndpointBackup -Endpoints $currentEndpoints

    $completed = [System.Collections.Generic.List[psobject]]::new()
    $allOk     = $true

    foreach ($op in $validatedOps) {
        $label = "$($op.Direction) Pin $($op.PinNumber)"
        Write-HubLog "Applying: $label - $($op.Action)" -Level ACTION

        $err = $null

        switch ($op.Action) {
            'Rename' {
                $err = [SafeRegHelper]::WriteValueSafe(
                    $op.PropKeyPath, $FriendlyNameProp,
                    $op.TargetName, [Microsoft.Win32.RegistryValueKind]::String)
            }
            'Enable' {
                $err = [SafeRegHelper]::WriteValueSafe(
                    $op.BaseKeyPath, 'DeviceState',
                    $DeviceStateActive, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            'RenameAndEnable' {
                $err = [SafeRegHelper]::WriteValueSafe(
                    $op.PropKeyPath, $FriendlyNameProp,
                    $op.TargetName, [Microsoft.Win32.RegistryValueKind]::String)
                if (-not $err) {
                    $err = [SafeRegHelper]::WriteValueSafe(
                        $op.BaseKeyPath, 'DeviceState',
                        $DeviceStateActive, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
            }
            'Disable' {
                $err = [SafeRegHelper]::WriteValueSafe(
                    $op.BaseKeyPath, 'DeviceState',
                    $DeviceStateDisabled, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
        }

        if ($err) {
            Write-HubLog "FAILED: $label - $err" -Level ERROR
            Write-Host "  [FAIL] $label : $err" -ForegroundColor Red
            $allOk = $false
            break
        }

        Write-HubLog "OK: $label" -Level ACTION
        Write-Host "  [OK] $label" -ForegroundColor Green
        $completed.Add($op)
    }

    # -- Rollback on failure -------------------------------------------------
    if (-not $allOk -and $completed.Count -gt 0) {
        Write-HubLog "Rolling back $($completed.Count) completed operation(s)..." -Level ROLLBACK
        Write-Host ''
        Write-Host '  [ROLLBACK] Reverting completed changes...' -ForegroundColor DarkYellow

        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json

        foreach ($done in $completed) {
            $entry = $backup.Entries | Where-Object {
                $_.BaseKeyPath -eq $done.BaseKeyPath
            } | Select-Object -First 1

            if (-not $entry) {
                Write-HubLog "No backup entry for $($done.BaseKeyPath) - cannot rollback." -Level ERROR
                continue
            }

            $label = "$($done.Direction) Pin $($done.PinNumber)"

            if ($done.Action -in @('Rename', 'RenameAndEnable')) {
                $rbErr = [SafeRegHelper]::WriteValueSafe(
                    $done.PropKeyPath, $FriendlyNameProp,
                    $entry.FriendlyName, [Microsoft.Win32.RegistryValueKind]::String)
                if ($rbErr) {
                    Write-HubLog "Rollback FAILED for $label name: $rbErr" -Level ERROR
                } else {
                    Write-HubLog "Rolled back name for $label" -Level ROLLBACK
                }
            }

            if ($done.Action -in @('Enable', 'RenameAndEnable', 'Disable')) {
                $rbErr = [SafeRegHelper]::WriteValueSafe(
                    $done.BaseKeyPath, 'DeviceState',
                    [int]$entry.DeviceState, [Microsoft.Win32.RegistryValueKind]::DWord)
                if ($rbErr) {
                    Write-HubLog "Rollback FAILED for $label state: $rbErr" -Level ERROR
                } else {
                    Write-HubLog "Rolled back state for $label" -Level ROLLBACK
                }
            }
        }

        Write-Host '  [ROLLBACK] Done.' -ForegroundColor DarkYellow
        Write-Host ''
        Write-Host "  Backup file preserved at: $backupPath" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Press Enter to close...' -ForegroundColor Gray
        Read-Host | Out-Null
        exit $Script:ExitCodes.RollbackFailed
    }

    if (-not $allOk) {
        Write-Host '  No operations completed. Nothing to roll back.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press Enter to close...' -ForegroundColor Gray
        Read-Host | Out-Null
        exit $Script:ExitCodes.RegistryFailed
    }

    # -- Success - offer audio service restart -------------------------------
    Write-Host ''
    Write-Host "  [+] All $($completed.Count) operation(s) applied successfully." -ForegroundColor Green
    Write-Host "  Backup: $backupPath" -ForegroundColor Gray
    Write-HubLog "Apply complete - $($completed.Count) operation(s)." -Level ACTION

    Write-Host ''
    Write-Host '  Windows Audio service must restart for updated names to appear.' -ForegroundColor Yellow
    if (Request-HubConfirmation -Prompt '  Restart Windows Audio service now?') {
        Write-HubLog 'User requested audio service restart.' -Level ACTION
        try {
            Restart-Service audiosrv -Force -ErrorAction Stop
            Write-Host '  [+] Windows Audio restarted.' -ForegroundColor Green
            Write-Host '  [!] If the Sound Control Panel (mmsys.cpl) is currently open,' -ForegroundColor Cyan
            Write-Host '      close and reopen it to see the updated device names.' -ForegroundColor Cyan
            Write-HubLog 'audiosrv restarted.' -Level ACTION

            if (Request-HubConfirmation -Prompt '  Open Sound Control Panel (mmsys.cpl) now?' -DefaultNo) {
                Start-Process 'control.exe' -ArgumentList 'mmsys.cpl'
            }
        } catch {
            Write-HubLog "audiosrv restart failed: $($_.Exception.Message)" -Level WARN
            Write-Host '  [WARN] Could not restart service. A PC reboot will apply the changes.' -ForegroundColor Yellow
        }
    } else {
        Write-Host '  [i] Audio service not restarted. Changes will take effect after reboot or manual restart.' -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '  Press Enter to continue...' -ForegroundColor Gray
    Read-Host | Out-Null
    if (-not (Test-HubIsAdmin)) { exit $Script:ExitCodes.Success }
}

# ============================================================================
#  RESTORE (runs elevated)
# ============================================================================
function Invoke-EndpointRestore {
    [CmdletBinding()]
    param()

    if (-not $BackupFile -or -not (Test-Path -LiteralPath $BackupFile)) {
        Write-HubLog "Backup file not found: $BackupFile" -Level ERROR
        exit $Script:ExitCodes.InvalidArgument
    }

    $backup = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
    Write-HubLog "Restoring from backup: $BackupFile (timestamp: $($backup.Timestamp))" -Level ROLLBACK
    Write-Host ''
    Write-Host "  Restoring from: $BackupFile" -ForegroundColor Cyan
    Write-Host "  Backup timestamp: $($backup.Timestamp)" -ForegroundColor Cyan
    Write-Host ''

    # Fresh scan of verified endpoints - do NOT write to arbitrary paths from JSON
    $currentEndpoints = Get-VBMatrixEndpoints
    if ($currentEndpoints.Count -eq 0) {
        Write-HubLog 'No verified VB-Audio Matrix endpoints found during live scan.' -Level ERROR
        Write-Host '  [FAIL] No verified VB-Audio Matrix endpoints found on this machine.' -ForegroundColor Red
        exit $Script:ExitCodes.RegistryFailed
    }

    $restored = 0
    $failed   = 0

    foreach ($entry in $backup.Entries) {
        if ($entry.GuidKey -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') {
            Write-HubLog "Skipping invalid GuidKey in backup: '$($entry.GuidKey)'" -Level ERROR
            $failed++
            continue
        }

        # Must match a verified endpoint from live scan
        $matched = $currentEndpoints | Where-Object {
            $_.GuidKey -eq $entry.GuidKey -and
            $_.Direction -eq $entry.Direction
        } | Select-Object -First 1

        if (-not $matched) {
            Write-HubLog "Skipping unverified endpoint in backup: $($entry.GuidKey)" -Level WARN
            continue
        }

        # Reconstruct paths strictly from verified live scan
        $safeBaseKey = $matched.BaseKeyPath
        $safePropKey = $matched.PropKeyPath
        $label = "$($matched.Direction) Pin $($matched.PinNumber)"

        $nameToRestore = [string]$entry.FriendlyName
        if ($nameToRestore.Length -gt 260) {
            Write-HubLog "Invalid friendly name length for $label" -Level ERROR
            $failed++
            continue
        }

        $stateToRestore = [int]$entry.DeviceState
        if ($stateToRestore -notin @($DeviceStateActive, $DeviceStateDisabled, 0, 1, 2, 4, 8)) {
            Write-HubLog "Invalid state value ($stateToRestore) for $label" -Level ERROR
            $failed++
            continue
        }

        # Restore friendly name
        $nameErr = [SafeRegHelper]::WriteValueSafe(
            $safePropKey, $FriendlyNameProp,
            $nameToRestore, [Microsoft.Win32.RegistryValueKind]::String)
        if ($nameErr) {
            Write-HubLog "Restore name FAILED for $label : $nameErr" -Level ERROR
            Write-Host "  [FAIL] $label name: $nameErr" -ForegroundColor Red
            $failed++
        } else {
            Write-HubLog "Restored name for $label : $nameToRestore" -Level ROLLBACK
        }

        # Restore device state
        $stateErr = [SafeRegHelper]::WriteValueSafe(
            $safeBaseKey, 'DeviceState',
            $stateToRestore, [Microsoft.Win32.RegistryValueKind]::DWord)
        if ($stateErr) {
            Write-HubLog "Restore state FAILED for $label : $stateErr" -Level ERROR
            Write-Host "  [FAIL] $label state: $stateErr" -ForegroundColor Red
            $failed++
        } else {
            Write-HubLog "Restored state for $label : $stateToRestore" -Level ROLLBACK
        }

        # Restore original SDDLs - fail if restore fails
        $sddlFailed = $false
        if ($entry.BaseSddl) {
            $sddlErr = [SafeRegHelper]::RestoreSddl($safeBaseKey, $entry.BaseSddl)
            if ($sddlErr) {
                Write-HubLog "Restore base SDDL FAILED for $label : $sddlErr" -Level ERROR
                Write-Host "  [FAIL] $label base SDDL: $sddlErr" -ForegroundColor Red
                $failed++
                $sddlFailed = $true
            } else {
                Write-HubLog "Restored base SDDL for $label" -Level ROLLBACK
            }
        }
        if ($entry.PropSddl) {
            $sddlErr = [SafeRegHelper]::RestoreSddl($safePropKey, $entry.PropSddl)
            if ($sddlErr) {
                Write-HubLog "Restore prop SDDL FAILED for $label : $sddlErr" -Level ERROR
                Write-Host "  [FAIL] $label prop SDDL: $sddlErr" -ForegroundColor Red
                $failed++
                $sddlFailed = $true
            } else {
                Write-HubLog "Restored prop SDDL for $label" -Level ROLLBACK
            }
        }

        if (-not $nameErr -and -not $stateErr -and -not $sddlFailed) {
            $restored++
            Write-Host "  [OK] $label -> '$nameToRestore' state=$stateToRestore" -ForegroundColor Green
        }
    }

    Write-Host ''
    if ($failed -gt 0) {
        Write-Host "  Restored $restored endpoint(s) with $failed failure(s)." -ForegroundColor Yellow
    } else {
        Write-Host "  [+] All $restored endpoint(s) restored successfully." -ForegroundColor Green
    }

    # Offer service restart
    Write-Host ''
    Write-Host '  Windows Audio service must restart for restored names to appear.' -ForegroundColor Yellow
    if (Request-HubConfirmation -Prompt '  Restart Windows Audio service now?') {
        try {
            Restart-Service audiosrv -Force -ErrorAction Stop
            Write-Host '  [+] Windows Audio restarted.' -ForegroundColor Green
            Write-Host '  [!] If the Sound Control Panel (mmsys.cpl) is currently open,' -ForegroundColor Cyan
            Write-Host '      close and reopen it to see the restored device names.' -ForegroundColor Cyan
            Write-HubLog 'audiosrv restarted after restore.' -Level ACTION

            if (Request-HubConfirmation -Prompt '  Open Sound Control Panel (mmsys.cpl) now?' -DefaultNo) {
                Start-Process 'control.exe' -ArgumentList 'mmsys.cpl'
            }
        } catch {
            Write-Host '  [WARN] Could not restart service. Reboot to apply.' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host '  Press Enter to continue...' -ForegroundColor Gray
    Read-Host | Out-Null

    if ($failed -gt 0) {
        if (-not (Test-HubIsAdmin)) { exit $Script:ExitCodes.RestoreFailed }
        return
    }
    if (-not (Test-HubIsAdmin)) { exit $Script:ExitCodes.Success }
}

# ============================================================================
#  MENU MODE (unelevated)
# ============================================================================
function Show-EndpointMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Write-Host ''
        Write-Host '===============================================================================' -ForegroundColor Cyan
        Write-Host '               AUDIO ENDPOINT MANAGER (VB-Audio Matrix)'                        -ForegroundColor Cyan
        Write-Host '===============================================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  [P] Preview  - show every proposed rename, enable, and disable'    -ForegroundColor White
        Write-Host '  [A] Apply    - rename and configure endpoints (requires Admin)'    -ForegroundColor White
        Write-Host '  [R] Restore  - undo changes from a backup    (requires Admin)'    -ForegroundColor White
        Write-Host '  [B] Back'                                                          -ForegroundColor White
        Write-Host ''

        $choice = Read-Host '  Select [P/A/R/B]'

        switch -Regex ($choice) {

            # -- Preview --------------------------------------------------
            '^[Pp]$' {
                Show-EndpointPreview | Out-Null
            }

            # -- Apply ----------------------------------------------------
            '^[Aa]$' {
                $endpoints = Show-EndpointPreview

                $pending = @($endpoints | Where-Object { $_.Action -ne 'Skip' })
                if ($pending.Count -eq 0) {
                    Write-Host '  All endpoints are already correctly configured.' -ForegroundColor Green
                    continue
                }

                # Separate confirmation for disabling endpoints 6-8
                $disables = @($pending | Where-Object { $_.Action -eq 'Disable' })
                $others   = @($pending | Where-Object { $_.Action -ne 'Disable' })

                $opsToApply = [System.Collections.Generic.List[psobject]]::new()

                if ($others.Count -gt 0) {
                    Write-Host ''
                    Write-Host "  $($others.Count) rename/enable operation(s) proposed." -ForegroundColor Cyan
                    if (Request-HubConfirmation -Prompt '  Proceed with rename/enable operations?') {
                        foreach ($o in $others) { $opsToApply.Add($o) }
                    }
                }

                if ($disables.Count -gt 0) {
                    Write-Host ''
                    Write-Host "  $($disables.Count) DISABLE operation(s) proposed (endpoints 6-8):" -ForegroundColor Yellow
                    foreach ($d in $disables) {
                        Write-Host "    $($d.Direction) Pin $($d.PinNumber): '$($d.CurrentName)'" -ForegroundColor Yellow
                    }
                    if (Request-HubConfirmation -Prompt '  Disable these endpoints?' -DefaultNo) {
                        foreach ($d in $disables) { $opsToApply.Add($d) }
                    } else {
                        Write-Host '  [i] Disable operations skipped.' -ForegroundColor Gray
                    }
                }

                if ($opsToApply.Count -eq 0) {
                    Write-Host '  No operations selected.' -ForegroundColor Yellow
                    continue
                }

                # Write plan JSON
                $planDir = $Script:HubConfig.BackupDirectory
                if (-not (Test-Path -LiteralPath $planDir)) {
                    New-Item -ItemType Directory -Path $planDir -Force | Out-Null
                }
                $planPath = Join-Path $planDir "endpoint_plan_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                $planObj  = [pscustomobject]@{
                    Timestamp  = (Get-Date -Format 'o')
                    Operations = @($opsToApply | ForEach-Object {
                        [pscustomobject]@{
                            Direction   = $_.Direction
                            PinNumber   = $_.PinNumber
                            GuidKey     = $_.GuidKey
                            BaseKeyPath = $_.BaseKeyPath
                            PropKeyPath = $_.PropKeyPath
                            Action      = $_.Action
                            TargetName  = $_.TargetName
                            TargetState = $_.TargetState
                        }
                    })
                }
                $planObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $planPath -Encoding UTF8
                Write-HubLog "Plan written: $planPath ($($opsToApply.Count) ops)" -Level ACTION

                # Run directly if already elevated, or request elevation
                if (Test-HubIsAdmin) {
                    Write-Host '  Running with current administrator privileges...' -ForegroundColor Cyan
                    $PlanFile = $planPath
                    Invoke-EndpointApply
                } else {
                    Write-Host ''
                    Write-Host '  Requesting administrator privileges...' -ForegroundColor Yellow

                    $scriptPath = $MyInvocation.ScriptName
                    if (-not $scriptPath) { $scriptPath = $PSCommandPath }

                    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode ApplyElevated -PlanFile `"$planPath`""

                    $elevated = Start-Process -FilePath $psExe -ArgumentList $argStr -Verb RunAs -Wait -PassThru -ErrorAction Stop

                    if ($elevated.ExitCode -eq 0) {
                        Write-Host '  [+] Apply completed successfully.' -ForegroundColor Green
                    } else {
                        Write-Host "  [FAIL] Apply exited with code $($elevated.ExitCode)." -ForegroundColor Red
                    }
                    Write-HubLog "Elevated apply exited with code $($elevated.ExitCode)." -Level ACTION
                }
            }

            # -- Restore --------------------------------------------------
            '^[Rr]$' {
                $backupDir = $Script:HubConfig.BackupDirectory
                if (-not (Test-Path -LiteralPath $backupDir)) {
                    Write-Host '  No backups directory found.' -ForegroundColor Yellow
                    continue
                }
                $backups = Get-ChildItem -LiteralPath $backupDir -Filter 'endpoint_backup_*.json' -File |
                           Sort-Object Name -Descending
                if ($backups.Count -eq 0) {
                    Write-Host '  No endpoint backups found.' -ForegroundColor Yellow
                    continue
                }

                Write-Host ''
                Write-Host '  Available backups:' -ForegroundColor Cyan
                for ($i = 0; $i -lt $backups.Count; $i++) {
                    Write-Host "    [$($i+1)] $($backups[$i].Name)" -ForegroundColor White
                }
                $sel = Read-Host "  Select backup [1-$($backups.Count)]"
                $idx = 0
                if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $backups.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Yellow
                    continue
                }

                $selectedBackup = $backups[$idx - 1].FullName
                Write-Host "  Selected: $($backups[$idx-1].Name)" -ForegroundColor Cyan

                if (-not (Request-HubConfirmation -Prompt '  Restore all values from this backup?' -DefaultNo)) {
                    Write-Host '  Restore cancelled.' -ForegroundColor Yellow
                    continue
                }

                if (Test-HubIsAdmin) {
                    Write-Host '  Running with current administrator privileges...' -ForegroundColor Cyan
                    $BackupFile = $selectedBackup
                    Invoke-EndpointRestore
                } else {
                    $scriptPath = $MyInvocation.ScriptName
                    if (-not $scriptPath) { $scriptPath = $PSCommandPath }

                    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode RestoreElevated -BackupFile `"$selectedBackup`""

                    $elevated = Start-Process -FilePath $psExe -ArgumentList $argStr -Verb RunAs -Wait -PassThru -ErrorAction Stop

                    if ($elevated.ExitCode -eq 0) {
                        Write-Host '  [+] Restore completed successfully.' -ForegroundColor Green
                    } else {
                        Write-Host "  [FAIL] Restore exited with code $($elevated.ExitCode)." -ForegroundColor Red
                    }
                }
            }

            # -- Back -----------------------------------------------------
            '^[Bb]$' { return }

            default {
                Write-Host '  Invalid selection.' -ForegroundColor Yellow
            }
        }
    }
}

# ============================================================================
#  MODE DISPATCH
# ============================================================================
switch ($Mode) {
    'Menu'             { Show-EndpointMenu     }
    'Preview'          { Show-EndpointPreview | Out-Null }
    'ApplyElevated'    { Invoke-EndpointApply  }
    'RestoreElevated'  { Invoke-EndpointRestore }
}

Write-HubLog "Mode '$Mode' finished." -Level INFO
