#Requires -Version 5.1
<#
.SYNOPSIS
    Launch, restart, diagnose, and manage VB-Audio Matrix + Ableton Live.
.DESCRIPTION
    Called from audio hub.bat with -Action <verb>.
    Actions: Launch, Restart, Settings, Diagnostics, GenerateXml
    Runs UNELEVATED.  Does not touch the registry or require admin.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Launch','Restart','Settings','Diagnostics','GenerateXml')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hub-Common.ps1')

$logFile = Initialize-HubLog -Component "Launch_$Action"

# ============================================================================
#  PATH DETECTION
# ============================================================================
function Find-MatrixExe {
    $paths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'VB\VBAudioMatrix\VBAudioMatrixCoconut_x64.exe')
        (Join-Path $env:ProgramFiles        'VB\VBAudioMatrix\VBAudioMatrixCoconut_x64.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'VB\VBAudioMatrix\VBAudioMatrix_x64.exe')
        (Join-Path $env:ProgramFiles        'VB\VBAudioMatrix\VBAudioMatrix_x64.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter\voicemeeter8x64.exe')
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-AbletonExe {
    $paths = @(
        'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
        "$env:ProgramFiles\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe"
        'C:\ProgramData\Ableton\Live 12 Standard\Program\Ableton Live 12 Standard.exe'
        "$env:ProgramFiles\Ableton\Live 12 Standard\Program\Ableton Live 12 Standard.exe"
        'C:\ProgramData\Ableton\Live 11 Suite\Program\Ableton Live 11 Suite.exe'
        "$env:ProgramFiles\Ableton\Live 11 Suite\Program\Ableton Live 11 Suite.exe"
        'C:\ProgramData\Ableton\Live 11 Standard\Program\Ableton Live 11 Standard.exe'
        "$env:ProgramFiles\Ableton\Live 11 Standard\Program\Ableton Live 11 Standard.exe"
        'C:\ProgramData\Ableton\Live 10 Suite\Program\Ableton Live 10 Suite.exe'
        "$env:ProgramFiles\Ableton\Live 10 Suite\Program\Ableton Live 10 Suite.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    # Registry fallback
    try {
        $regKey = 'Registry::HKCR\Ableton.LiveProject\shell\open\command'
        if (Test-Path -LiteralPath $regKey) {
            $val = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).'(default)'
            if ($val -match '"([^"]+)"') {
                $candidate = $Matches[1]
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    } catch { }
    return $null
}

function Find-AlsFile {
    # Check root first
    $files = Get-ChildItem -LiteralPath $Script:RepoRoot -Filter '*.als' -File -ErrorAction SilentlyContinue
    if ($files -and $files.Count -gt 0) { return $files[0].FullName }
    # Check project subfolders (excluding Backup folders)
    $subFiles = Get-ChildItem -LiteralPath $Script:RepoRoot -Filter '*.als' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notlike '*Backup*' }
    if ($subFiles -and $subFiles.Count -gt 0) { return $subFiles[0].FullName }
    return $null
}

# ============================================================================
#  PROCESS HELPERS
# ============================================================================
function Get-MatrixProcess {
    foreach ($name in $Script:HubConfig.MatrixProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) { return $procs }
    }
    return $null
}

function Stop-MatrixGracefully {
    [CmdletBinding()]
    param()

    $procs = Get-MatrixProcess
    if (-not $procs) {
        Write-HubLog 'No Matrix processes running.' -Level INFO
        return $true
    }

    Write-Host ''
    Write-Host '  [!] VB-Audio Matrix is currently running:' -ForegroundColor Yellow
    foreach ($p in $procs) {
        Write-Host "      PID $($p.Id): $($p.ProcessName)" -ForegroundColor Yellow
    }

    if (-not (Request-HubConfirmation -Prompt '  Close VB-Audio Matrix?' -DefaultNo)) {
        Write-HubLog 'User declined to close Matrix.' -Level ACTION
        return $false
    }

    # Graceful: send WM_CLOSE via CloseMainWindow
    Write-HubLog 'Attempting graceful close (CloseMainWindow)...' -Level ACTION
    foreach ($p in $procs) {
        try {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                $p.CloseMainWindow() | Out-Null
            }
        } catch { }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($Script:HubConfig.GracefulCloseWaitSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if (-not (Get-MatrixProcess)) {
            Write-HubLog 'Matrix closed gracefully.' -Level ACTION
            Write-Host '  [+] Matrix closed.' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    # Still alive - ask separately before force-close
    $remaining = Get-MatrixProcess
    if ($remaining) {
        Write-Host '  [!] Matrix did not close gracefully.' -ForegroundColor Yellow
        if (-not (Request-HubConfirmation -Prompt '  Force-close Matrix? Unsaved changes will be lost.' -DefaultNo)) {
            Write-HubLog 'User declined force-close.' -Level ACTION
            return $false
        }
        Write-HubLog 'Force-closing Matrix processes...' -Level ACTION
        foreach ($p in $remaining) {
            try {
                $p.Kill()
                $p.WaitForExit(5000) | Out-Null
                Write-HubLog "Killed PID $($p.Id)." -Level ACTION
            } catch {
                Write-HubLog "Failed to kill PID $($p.Id): $($_.Exception.Message)" -Level ERROR
            }
        }
        Start-Sleep -Seconds 1
        if (Get-MatrixProcess) {
            Write-HubLog 'Some Matrix processes may still be running.' -Level WARN
            return $false
        }
        Write-Host '  [+] Matrix force-closed.' -ForegroundColor Green
    }
    return $true
}

# ============================================================================
#  XML PRESET GENERATION
# ============================================================================
function New-RoutingXmlPreset {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '             VB-AUDIO MATRIX CONFIGURATION PRESETS (VBM)'                        -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    $vbmDir = Join-Path $Script:RepoRoot 'VBM'
    if (-not (Test-Path -LiteralPath $vbmDir)) {
        New-Item -ItemType Directory -Path $vbmDir -Force | Out-Null
    }

    # 1. Total Configuration Preset (Devices + Slots + Clock + 49-pt Grid)
    $totalSource = Join-Path $vbmDir 'Everything 32 track.xml'
    $totalTarget = Join-Path $Script:RepoRoot 'Everything 32 track.xml'

    # 2. Grid Routing Preset (49 Cross-points only)
    $gridSource  = Join-Path $vbmDir 'Routing 32 track.xml'
    $gridTarget  = Join-Path $Script:RepoRoot 'Routing 32 track.xml'
    $gridTarget2 = Join-Path $Script:RepoRoot 'Routing_32_Track.xml'

    # Copy / Deploy Total Configuration
    if (Test-Path -LiteralPath $totalSource) {
        Copy-Item -LiteralPath $totalSource -Destination $totalTarget -Force
        Write-Host '  [+] Deployed: Everything 32 track.xml  (Total Configuration)' -ForegroundColor Green
        Write-HubLog "Deployed Total Configuration to $totalTarget" -Level ACTION
    }

    # Copy / Deploy Grid Settings
    if (Test-Path -LiteralPath $gridSource) {
        Copy-Item -LiteralPath $gridSource -Destination $gridTarget -Force
        Copy-Item -LiteralPath $gridSource -Destination $gridTarget2 -Force
        Write-Host '  [+] Deployed: Routing 32 track.xml     (Grid Routing 49-point matrix)' -ForegroundColor Green
        Write-HubLog "Deployed Grid Settings to $gridTarget" -Level ACTION
    } else {
        # Fallback generator for authentic 49 points if VBM\Routing 32 track.xml missing
        $points = @(
            @{ slotin='WIN1.IN';  sin=1;  slotout='VASIO8';   sout=1  }
            @{ slotin='ASIO32';   sin=1;  slotout='VASIO32';  sout=1  }
            @{ slotin='ASIO32';   sin=2;  slotout='VASIO32';  sout=2  }
            @{ slotin='VAIO1';    sin=1;  slotout='VASIO8';   sout=3  }
            @{ slotin='VAIO1';    sin=1;  slotout='VASIO32';  sout=3  }
            @{ slotin='VAIO1';    sin=2;  slotout='VASIO8';   sout=4  }
            @{ slotin='VAIO1';    sin=2;  slotout='VASIO32';  sout=4  }
            @{ slotin='VAIO2';    sin=1;  slotout='VASIO8';   sout=5  }
            @{ slotin='VAIO2';    sin=1;  slotout='VASIO32';  sout=5  }
            @{ slotin='VAIO2';    sin=2;  slotout='VASIO8';   sout=6  }
            @{ slotin='VAIO2';    sin=2;  slotout='VASIO32';  sout=6  }
            @{ slotin='VAIO3';    sin=1;  slotout='VASIO8';   sout=7  }
            @{ slotin='VAIO3';    sin=1;  slotout='VASIO32';  sout=7  }
            @{ slotin='VAIO3';    sin=2;  slotout='VASIO8';   sout=8  }
            @{ slotin='VAIO3';    sin=2;  slotout='VASIO32';  sout=8  }
            @{ slotin='VAIO4';    sin=1;  slotout='VASIO32';  sout=9  }
            @{ slotin='VAIO4';    sin=2;  slotout='VASIO32';  sout=10 }
            @{ slotin='VAIO5';    sin=1;  slotout='VASIO32';  sout=11 }
            @{ slotin='VAIO5';    sin=2;  slotout='VASIO32';  sout=12 }
            @{ slotin='VAIO6';    sin=1;  slotout='VASIO32';  sout=11 }
            @{ slotin='VAIO6';    sin=2;  slotout='VASIO32';  sout=12 }
            @{ slotin='VAIO7';    sin=1;  slotout='VASIO32';  sout=15 }
            @{ slotin='VAIO7';    sin=2;  slotout='VASIO32';  sout=16 }
            @{ slotin='VAIO8';    sin=1;  slotout='VASIO32';  sout=17 }
            @{ slotin='VAIO8';    sin=2;  slotout='VASIO32';  sout=18 }
            @{ slotin='VASIO8';   sin=1;  slotout='WIN1.OUT'; sout=1  }
            @{ slotin='VASIO8';   sin=2;  slotout='WIN1.OUT'; sout=2  }
            @{ slotin='VASIO8';   sin=3;  slotout='VAIO1';    sout=1  }
            @{ slotin='VASIO8';   sin=4;  slotout='VAIO1';    sout=2  }
            @{ slotin='VASIO32';  sin=1;  slotout='ASIO32';   sout=1  }
            @{ slotin='VASIO32';  sin=1;  slotout='ASIO64A';  sout=1  }
            @{ slotin='VASIO32';  sin=1;  slotout='ASIO64B';  sout=1  }
            @{ slotin='VASIO32';  sin=1;  slotout='WIN1.OUT'; sout=1  }
            @{ slotin='VASIO32';  sin=1;  slotout='WIN2.OUT'; sout=1  }
            @{ slotin='VASIO32';  sin=1;  slotout='WIN32.OUT';sout=1  }
            @{ slotin='VASIO32';  sin=2;  slotout='ASIO32';   sout=2  }
            @{ slotin='VASIO32';  sin=2;  slotout='ASIO64A';  sout=2  }
            @{ slotin='VASIO32';  sin=2;  slotout='ASIO64B';  sout=2  }
            @{ slotin='VASIO32';  sin=2;  slotout='WIN1.OUT'; sout=2  }
            @{ slotin='VASIO32';  sin=2;  slotout='WIN2.OUT'; sout=2  }
            @{ slotin='VASIO32';  sin=2;  slotout='WIN32.OUT';sout=2  }
            @{ slotin='VASIO32';  sin=5;  slotout='VAIO1';    sout=1  }
            @{ slotin='VASIO32';  sin=6;  slotout='VAIO1';    sout=2  }
            @{ slotin='VASIO32';  sin=7;  slotout='VAIO2';    sout=1  }
            @{ slotin='VASIO32';  sin=8;  slotout='VAIO2';    sout=2  }
            @{ slotin='VASIO32';  sin=9;  slotout='VAIO3';    sout=1  }
            @{ slotin='VASIO32';  sin=10; slotout='VAIO3';    sout=2  }
            @{ slotin='VASIO32';  sin=11; slotout='VAIO4';    sout=1  }
            @{ slotin='VASIO32';  sin=12; slotout='VAIO4';    sout=2  }
        )

        $doc  = [System.Xml.XmlDocument]::new()
        $decl = $doc.CreateXmlDeclaration('1.0', 'utf-8', $null)
        $doc.AppendChild($decl) | Out-Null

        $root = $doc.CreateElement('VBAudioMatrixGridSettings')
        $doc.AppendChild($root) | Out-Null

        $cfg = $doc.CreateElement('VBAudioMatrixGridConfiguration')
        $root.AppendChild($cfg) | Out-Null

        foreach ($pt in $points) {
            $el = $doc.CreateElement('Point')
            $el.SetAttribute('slotin',  $pt.slotin)
            $el.SetAttribute('in',      [string]$pt.sin)
            $el.SetAttribute('slotout', $pt.slotout)
            $el.SetAttribute('out',     [string]$pt.sout)
            $el.SetAttribute('dBGain',  '0.00')
            $el.SetAttribute('mute',    '0')
            $el.SetAttribute('phase',   '0')
            $cfg.AppendChild($el) | Out-Null
        }

        $ws             = [System.Xml.XmlWriterSettings]::new()
        $ws.Indent      = $true
        $ws.IndentChars = '    '
        $ws.Encoding    = [System.Text.UTF8Encoding]::new($false)

        $writer = [System.Xml.XmlWriter]::Create($gridTarget, $ws)
        try     { $doc.WriteTo($writer) }
        finally { $writer.Close() }

        Copy-Item -LiteralPath $gridTarget -Destination $gridTarget2 -Force
        Copy-Item -LiteralPath $gridTarget -Destination $gridSource -Force
        Write-Host '  [+] Generated: Routing 32 track.xml (49 routing points)' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  =============================================================================' -ForegroundColor Cyan
    Write-Host '  HOW TO LOAD PRESETS IN VB-AUDIO MATRIX COCONUT:'                              -ForegroundColor Cyan
    Write-Host '  =============================================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  STEP 1: Load Total Configuration (REQUIRED FIRST TIME):' -ForegroundColor White
    Write-Host '    1. In VB-Audio Matrix window, click top menu bar.' -ForegroundColor White
    Write-Host '    2. Click "Load Total Configuration..."' -ForegroundColor Yellow
    Write-Host '    3. Select: "Everything 32 track.xml" (or "VBM\Everything 32 track.xml")' -ForegroundColor Yellow
    Write-Host '    -> This turns ON Matrix VAIO 1-5, Virtual ASIO 32, sets clock, and loads routing!' -ForegroundColor Green
    Write-Host ''
    Write-Host '  STEP 2: Load Grid Settings (Optional, to reload routing points later):' -ForegroundColor White
    Write-Host '    1. In VB-Audio Matrix window, click top menu bar.' -ForegroundColor White
    Write-Host '    2. Click "Load Grid / Routing Settings..."' -ForegroundColor Yellow
    Write-Host '    3. Select: "Routing 32 track.xml"' -ForegroundColor Yellow
    Write-Host ''
}

# ============================================================================
#  ACTION: LAUNCH
# ============================================================================
function Invoke-LaunchHub {
    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '                        STARTING LIVE AUDIO RIG...'                              -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    $matrixExe  = Find-MatrixExe
    $abletonExe = Find-AbletonExe
    $alsFile    = Find-AlsFile

    # Generate XML if missing
    $xmlPath = Join-Path $Script:RepoRoot 'Routing_32_Track.xml'
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        New-RoutingXmlPreset
    }

    # -- Matrix --
    $matrixRunning = $false
    if (-not $matrixExe) {
        Write-HubLog 'VB-Audio Matrix not found.' -Level WARN
        Write-Host '  [-] VB-Audio Matrix not found.' -ForegroundColor Red
        if (Request-HubConfirmation -Prompt '  Download and install it?' -DefaultNo) {
            & (Join-Path $PSScriptRoot 'Hub-Download.ps1')
            return
        }
    } else {
        Write-Host "  [+] Matrix: $matrixExe" -ForegroundColor Green

        if (-not (Test-HubLocalExe -FilePath $matrixExe -Label 'VB-Audio Matrix')) {
            Write-HubLog 'Matrix executable verification failed - not launching.' -Level ERROR
            return
        }

        if (Get-MatrixProcess) {
            Write-Host '  [i] Matrix is already running.' -ForegroundColor Gray
            $matrixRunning = $true
        } else {
            Write-HubLog "Starting Matrix: $matrixExe" -Level ACTION
            Start-Process -FilePath $matrixExe
            $deadline = [datetime]::UtcNow.AddSeconds($Script:HubConfig.ProcessStartWaitSeconds)
            while ([datetime]::UtcNow -lt $deadline) {
                if (Get-MatrixProcess) { $matrixRunning = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if ($matrixRunning) {
                Write-Host '  [+] Matrix started.' -ForegroundColor Green
            } else {
                Write-HubLog 'Matrix process not detected after launch.' -Level WARN
                Write-Host '  [WARN] Matrix may not have started - process not detected.' -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''

    # -- ALS file --
    if ($alsFile) {
        Write-Host "  [+] Live Set: $alsFile" -ForegroundColor Green
    } else {
        Write-Host '  [i] No adjacent .als project. Ableton will open its default template.' -ForegroundColor Gray
    }
    Write-Host ''

    # -- Ableton --
    $abletonRunning = $false
    if (-not $abletonExe) {
        Write-HubLog 'Ableton Live not found.' -Level WARN
        Write-Host '  [X] Ableton Live not detected.' -ForegroundColor Red
        if (Request-HubConfirmation -Prompt '  Open the Ableton Live trial page?' -DefaultNo) {
            Start-Process -FilePath 'https://www.ableton.com/en/trial/'
        }
    } else {
        Write-Host "  [+] Ableton: $abletonExe" -ForegroundColor Green

        if (-not (Test-HubLocalExe -FilePath $abletonExe -Label 'Ableton Live' -AllowModified)) {
            Write-HubLog 'Ableton executable verification failed - not launching.' -Level ERROR
            return
        }

        $procName = [System.IO.Path]::GetFileNameWithoutExtension($abletonExe)
        $existing = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host '  [i] Ableton Live is already running.' -ForegroundColor Gray
            $abletonRunning = $true
        } else {
            Write-HubLog "Launching Ableton: $abletonExe" -Level ACTION
            if ($alsFile) {
                Start-Process -FilePath $abletonExe -ArgumentList "`"$alsFile`""
            } else {
                Start-Process -FilePath $abletonExe
            }

            Write-Host '  [*] Waiting for Ableton to start...' -ForegroundColor Cyan
            $deadline = [datetime]::UtcNow.AddSeconds($Script:HubConfig.ProcessStartWaitSeconds)
            while ([datetime]::UtcNow -lt $deadline) {
                if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
                    $abletonRunning = $true; break
                }
                Start-Sleep -Milliseconds 500
            }
            if ($abletonRunning) {
                Write-Host '  [+] Ableton started.' -ForegroundColor Green
            } else {
                Write-HubLog 'Ableton process not detected after wait.' -Level WARN
                Write-Host '  [WARN] Ableton may not have started.' -ForegroundColor Yellow
            }
        }
    }

    Write-Host ''

    # -- Optional priority boost --
    $priority = $Script:HubConfig.DefaultPriority
    $priorityStatus = 'Unchanged (opt-in declined)'
    if (Request-HubConfirmation -Prompt "  Set CPU priority to ${priority}?") {
        Write-HubLog "Boosting priority to $priority..." -Level ACTION
        $names = @()
        if ($abletonExe) {
            $names += [System.IO.Path]::GetFileNameWithoutExtension($abletonExe)
        }
        $names += $Script:HubConfig.MatrixProcessNames
        $boosted = 0
        foreach ($n in $names) {
            $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                try {
                    $p.PriorityClass = $priority
                    Write-Host "  [+] Priority -> $priority : $($p.ProcessName) (PID $($p.Id))" -ForegroundColor Green
                    Write-HubLog "Priority $priority for $($p.ProcessName) PID $($p.Id)" -Level ACTION
                    $boosted++
                } catch {
                    Write-HubLog "Priority set failed for $($p.ProcessName): $($_.Exception.Message)" -Level WARN
                }
            }
        }
        if ($boosted -gt 0) {
            $priorityStatus = "$priority ($boosted process(es))"
        } else {
            $priorityStatus = 'Unchanged (no running processes found)'
            Write-Host '  [WARN] No processes found to boost.' -ForegroundColor Yellow
        }
    }

    # -- Summary --
    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    $mStat  = if ($matrixRunning)  { 'Running' } else { 'Not detected' }
    $mColor = if ($matrixRunning)  { 'Green'   } else { 'Yellow'       }
    $aStat  = if ($abletonRunning) { 'Running' } else { 'Not detected' }
    $aColor = if ($abletonRunning) { 'Green'   } else { 'Yellow'       }
    Write-Host "  Matrix Router : $mStat" -ForegroundColor $mColor
    Write-Host "  Ableton Host  : $aStat" -ForegroundColor $aColor
    $pColor = if ($priorityStatus -like "$priority*") { 'Green' } else { 'Gray' }
    Write-Host "  CPU Priority  : $priorityStatus" -ForegroundColor $pColor
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''
}

# ============================================================================
#  ACTION: RESTART (PANIC BUTTON)
# ============================================================================
function Invoke-RestartEngine {
    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '                   RESTARTING AUDIO ROUTING ENGINE'                              -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Stop-MatrixGracefully)) {
        Write-Host '  Matrix was not closed. Aborting restart.' -ForegroundColor Yellow
        return
    }
    Start-Sleep -Seconds 2
    Write-HubLog 'Relaunching audio rig...' -Level ACTION
    Invoke-LaunchHub
}

# ============================================================================
#  ACTION: AUDIO SETTINGS
# ============================================================================
function Invoke-AudioSettings {
    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '                       WINDOWS SOUND CONFIGURATION'                              -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-HubLog 'Opening Windows Sound Settings.' -Level ACTION
    Start-Process -FilePath 'ms-settings:sound'
    Start-Process -FilePath 'ms-settings:apps-volume'

    Write-Host '  [i] Per-App Routing Reference:'              -ForegroundColor Gray
    Write-Host '      Desktop Audio  -> Matrix VAIO 1 Output'  -ForegroundColor Gray
    Write-Host '      Voicechat      -> Matrix VAIO 2 Output'  -ForegroundColor Gray
    Write-Host '      Media / Music  -> Matrix VAIO 3 Output'  -ForegroundColor Gray
    Write-Host '      Browser        -> Matrix VAIO 4 Output'  -ForegroundColor Gray
    Write-Host '      Default Mic    -> Voicechat Mic (VAIO 1 Input)' -ForegroundColor Gray
    Write-Host ''
}

# ============================================================================
#  ACTION: DIAGNOSTICS
# ============================================================================
function Invoke-Diagnostics {
    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '             AUDIO ENGINE AND DRIVER DIAGNOSTIC REPORT'                          -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  [*] Registered ASIO Drivers:' -ForegroundColor Yellow
    Write-Host ''
    $found = $false
    foreach ($regPath in @('HKLM:\SOFTWARE\ASIO', 'HKCU:\SOFTWARE\ASIO')) {
        if (Test-Path -LiteralPath $regPath) {
            Get-ChildItem -LiteralPath $regPath | ForEach-Object {
                $desc = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).Description
                Write-Host "      $($_.PSChildName)  ($desc)" -ForegroundColor White
                $found = $true
            }
        }
    }
    if (-not $found) { Write-Host '      (none found)' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  [*] Audio Devices (VB-Audio / USB):' -ForegroundColor Yellow
    Get-CimInstance Win32_SoundDevice |
        Where-Object {
            $_.Manufacturer -like '*VB-Audio*' -or
            $_.Manufacturer -like '*Focusrite*' -or
            $_.Name         -like '*Matrix*'   -or
            $_.Name         -like '*USB*'
        } |
        ForEach-Object {
            Write-Host "      $($_.Name) - $($_.Status)" -ForegroundColor White
        }
    Write-Host ''
}

# ============================================================================
#  DISPATCH
# ============================================================================
switch ($Action) {
    'Launch'       { Invoke-LaunchHub     }
    'Restart'      { Invoke-RestartEngine }
    'Settings'     { Invoke-AudioSettings }
    'Diagnostics'  { Invoke-Diagnostics   }
    'GenerateXml'  { New-RoutingXmlPreset }
}

Write-HubLog "Action '$Action' finished." -Level INFO
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
