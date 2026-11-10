#Requires -Version 5.1
<#
.SYNOPSIS
    Quick Drop-in Module Swapper for Discord Voice (Zero Compiler Required).
.DESCRIPTION
    Swaps pre-compiled high-quality audio modules (1x, 2x, 5x, 10x Gain, 248k)
    into Discord, Discord Canary, PTB, Development, or Vencord.
    Automatically creates stock backups before replacing so changes can be
    reverted back to vanilla at any time.
    Runs UNELEVATED (Discord is installed in %LOCALAPPDATA%).
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Swap','Restore','List')]
    [string]$Action = 'Menu',

    [string]$Profile = '',
    [string]$Client  = 'All'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Hub-Common.ps1')

$logFile = Initialize-HubLog -Component 'DiscordModules'

# ============================================================================
#  DETECTION: INSTALLED DISCORD CLIENTS
# ============================================================================
function Get-InstalledDiscordClients {
    [CmdletBinding()]
    param()

    $clients = [System.Collections.Generic.List[psobject]]::new()
    $specs = @(
        @{ Name = 'Discord Stable';      Path = "$env:LOCALAPPDATA\Discord";            Exe = 'Discord.exe';            Proc = @('Discord') }
        @{ Name = 'Discord Canary';      Path = "$env:LOCALAPPDATA\DiscordCanary";      Exe = 'DiscordCanary.exe';      Proc = @('DiscordCanary') }
        @{ Name = 'Discord PTB';         Path = "$env:LOCALAPPDATA\DiscordPTB";         Exe = 'DiscordPTB.exe';         Proc = @('DiscordPTB') }
        @{ Name = 'Discord Development'; Path = "$env:LOCALAPPDATA\DiscordDevelopment"; Exe = 'DiscordDevelopment.exe'; Proc = @('DiscordDevelopment') }
        @{ Name = 'Vencord';             Path = "$env:LOCALAPPDATA\Vencord";            Exe = 'Discord.exe';            Proc = @('Vencord','Discord') }
    )

    foreach ($s in $specs) {
        if (-not (Test-Path -LiteralPath $s.Path)) { continue }

        $appDirs = Get-ChildItem -LiteralPath $s.Path -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending
        if (-not $appDirs -or $appDirs.Count -eq 0) { continue }
        $appDir = $appDirs[0]

        $modulesDir = Join-Path $appDir.FullName 'modules'
        if (-not (Test-Path -LiteralPath $modulesDir)) { continue }

        $voiceModules = Get-ChildItem -LiteralPath $modulesDir -Directory -Filter 'discord_voice*' -ErrorAction SilentlyContinue
        if (-not $voiceModules -or $voiceModules.Count -eq 0) { continue }

        $voiceMod = $voiceModules[0]
        $nested   = Join-Path $voiceMod.FullName 'discord_voice'
        $folder   = if (Test-Path -LiteralPath $nested) { $nested } else { $voiceMod.FullName }
        $nodeFile = Join-Path $folder 'discord_voice.node'
        if (-not (Test-Path -LiteralPath $nodeFile)) { continue }

        $stockBak  = Join-Path $folder 'discord_voice.node.original_stock'
        $updateExe = Join-Path $s.Path 'Update.exe'
        $exePath   = Join-Path $appDir.FullName $s.Exe

        $clients.Add([pscustomobject]@{
            Name          = $s.Name
            RootPath      = $s.Path
            AppDirectory  = $appDir.FullName
            Version       = ($appDir.Name -replace '^app-', '')
            VoiceFolder   = $folder
            VoiceNodePath = $nodeFile
            StockBackup   = $stockBak
            ProcessNames  = $s.Proc
            UpdateExe     = $updateExe
            ExePath       = $exePath
            ExeName       = $s.Exe
        })
    }
    return $clients
}

# ============================================================================
#  DETECTION: AVAILABLE PRE-COMPILED MODULES
# ============================================================================
function Get-AvailableModules {
    [CmdletBinding()]
    param()

    $searchDirs = @(
        (Join-Path $Script:RepoRoot 'z Modules'),
        (Join-Path $Script:RepoRoot 'modules')
    )

    $results = [ordered]@{}

    foreach ($base in $searchDirs) {
        if (-not (Test-Path -LiteralPath $base)) { continue }

        $profiles = @(
            @{ Key = '1'; Id = '1x';   Name = '[1x Gain] Clean Studio Stereo (384 kbps, 0dB)'; Dir = '[1x Gain]' }
            @{ Key = '2'; Id = '2x';   Name = '[2x Gain] Boosted Stereo (+6 dB)';             Dir = '[2x Gain]' }
            @{ Key = '3'; Id = '5x';   Name = '[5x Gain] Loud Stereo (+14 dB)';               Dir = '[5x Gain]' }
            @{ Key = '4'; Id = '10x';  Name = '[10x Gain] Maximum Gain (+20 dB)';             Dir = '[10x Gain]' }
            @{ Key = '5'; Id = '248k'; Name = '[248k] 248 kbps Optimized Profile';            Dir = '248k' }
        )

        foreach ($p in $profiles) {
            if ($results.Contains($p.Id)) { continue }
            $targetDir = Join-Path $base $p.Dir
            $nodePath  = Join-Path $targetDir 'discord_voice.node'
            if (Test-Path -LiteralPath $nodePath) {
                $results[$p.Id] = [pscustomobject]@{
                    Key         = $p.Key
                    Id          = $p.Id
                    Name        = $p.Name
                    Directory   = $targetDir
                    NodePath    = $nodePath
                    Size        = (Get-Item -LiteralPath $nodePath).Length
                }
            }
        }
    }
    return $results
}

# ============================================================================
#  PROCESS CONTROL
# ============================================================================
function Stop-DiscordProcesses {
    param([string[]]$ProcessNames)
    foreach ($name in $ProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($p in $procs) {
                try { $p.CloseMainWindow() | Out-Null } catch { }
            }
        }
    }
    Start-Sleep -Milliseconds 600
    foreach ($name in $ProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($p in $procs) {
                try {
                    $p.Kill()
                    $p.WaitForExit(3000) | Out-Null
                } catch { }
            }
        }
    }
}

function Start-DiscordClient {
    param([psobject]$Client)
    try {
        if ($Client.UpdateExe -and (Test-Path -LiteralPath $Client.UpdateExe)) {
            Start-Process -FilePath $Client.UpdateExe -ArgumentList "--processStart", $Client.ExeName
        } elseif ($Client.ExePath -and (Test-Path -LiteralPath $Client.ExePath)) {
            Start-Process -FilePath $Client.ExePath
        }
    } catch { }
}

# ============================================================================
#  SWAP & RESTORE OPERATIONS
# ============================================================================
function Swap-DiscordModule {
    param(
        [Parameter(Mandatory)][psobject]$Client,
        [psobject]$Module,
        [switch]$RestoreStock
    )

    Write-Host "  [*] Target: $($Client.Name) (version $($Client.Version))" -ForegroundColor Cyan

    # Ensure original stock backup exists before any change
    if (-not (Test-Path -LiteralPath $Client.StockBackup)) {
        try {
            Copy-Item -LiteralPath $Client.VoiceNodePath -Destination $Client.StockBackup -Force
            Write-HubLog "Saved stock backup: $($Client.StockBackup)" -Level BACKUP
            Write-Host "      [+] Saved original stock backup (safe revert enabled)." -ForegroundColor DarkCyan
        } catch {
            Write-HubLog "Failed to create stock backup: $($_.Exception.Message)" -Level ERROR
            Write-Host "      [!] Failed to create stock backup: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    # Stop processes so file is unlocked
    Stop-DiscordProcesses -ProcessNames $Client.ProcessNames

    if ($RestoreStock) {
        if (Test-Path -LiteralPath $Client.StockBackup) {
            try {
                Copy-Item -LiteralPath $Client.StockBackup -Destination $Client.VoiceNodePath -Force
                Write-HubLog "Restored $($Client.Name) to stock voice module." -Level ROLLBACK
                Write-Host "      [+] Restored to original stock Discord voice module." -ForegroundColor Green
                return $true
            } catch {
                Write-HubLog "Restore failed: $($_.Exception.Message)" -Level ERROR
                Write-Host "      [!] Restore failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "      [!] Stock backup file not found." -ForegroundColor Red
            return $false
        }
    } else {
        if (-not $Module -or -not (Test-Path -LiteralPath $Module.NodePath)) {
            Write-Host "      [!] Module file not found: $($Module.NodePath)" -ForegroundColor Red
            return $false
        }

        try {
            Copy-Item -LiteralPath $Module.NodePath -Destination $Client.VoiceNodePath -Force
            Write-HubLog "Swapped $($Client.Name) voice module -> $($Module.Name)" -Level ACTION
            Write-Host "      [+] Injected $($Module.Name) successfully." -ForegroundColor Green
            return $true
        } catch {
            Write-HubLog "Swap failed: $($_.Exception.Message)" -Level ERROR
            Write-Host "      [!] Swap failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# ============================================================================
#  INTERACTIVE MENU
# ============================================================================
function Show-ModuleSwapperMenu {
    [CmdletBinding()]
    param()

    while ($true) {
        Write-Host ''
        Write-Host '===============================================================================' -ForegroundColor Cyan
        Write-Host '          DISCORD VOICE MODULE SWAPPER (Zero Compiler Required)'                -ForegroundColor Cyan
        Write-Host '===============================================================================' -ForegroundColor Cyan
        Write-Host ''

        $clients = Get-InstalledDiscordClients
        if ($clients.Count -eq 0) {
            Write-Host '  [!] No installed Discord clients detected.' -ForegroundColor Yellow
            Write-Host '      Install Discord, Discord Canary, or PTB to use this tool.' -ForegroundColor Gray
            Write-Host ''
            return
        }

        Write-Host '  Detected Discord Clients:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $clients.Count; $i++) {
            $c = $clients[$i]
            $hasStock = Test-Path -LiteralPath $c.StockBackup
            $stockTag = if ($hasStock) { '[Stock backup available]' } else { '[Stock active]' }
            Write-Host "    [$($i+1)] $($c.Name) (v$($c.Version)) - $stockTag" -ForegroundColor White
        }

        $modules = Get-AvailableModules
        if ($modules.Count -eq 0) {
            Write-Host ''
            Write-Host '  [!] No pre-compiled modules found in z Modules\.' -ForegroundColor Yellow
            return
        }

        Write-Host ''
        Write-Host '  Available Pre-Compiled Profiles:' -ForegroundColor Yellow
        foreach ($m in $modules.Values) {
            Write-Host "    [$($m.Key)] $($m.Name)" -ForegroundColor White
        }
        Write-Host '    [R] Restore Stock Vanilla Voice (Revert)' -ForegroundColor Cyan
        Write-Host '    [B] Back to Main Menu' -ForegroundColor Gray
        Write-Host ''

        $profChoice = Read-Host '  Select profile [1-5, R, B]'

        if ($profChoice -match '^[Bb]$') { return }

        $restore = ($profChoice -match '^[Rr]$')
        $selectedModule = $null

        if (-not $restore) {
            $match = $modules.Values | Where-Object { $_.Key -eq $profChoice } | Select-Object -First 1
            if (-not $match) {
                Write-Host '  Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }
            $selectedModule = $match
        }

        Write-Host ''
        Write-Host '  Select target Discord client:' -ForegroundColor Yellow
        for ($i = 0; $i -lt $clients.Count; $i++) {
            Write-Host "    [$($i+1)] $($clients[$i].Name)" -ForegroundColor White
        }
        Write-Host "    [A] All Installed Clients ($($clients.Count) clients)" -ForegroundColor Green
        Write-Host '    [C] Cancel' -ForegroundColor Gray
        Write-Host ''

        $clientChoice = Read-Host "  Select client [1-$($clients.Count), A, C]"

        if ($clientChoice -match '^[Cc]$') { continue }

        $targets = @()
        if ($clientChoice -match '^[Aa]$') {
            $targets = @($clients)
        } else {
            $idx = 0
            if ([int]::TryParse($clientChoice, [ref]$idx) -and $idx -ge 1 -and $idx -le $clients.Count) {
                $targets = @($clients[$idx - 1])
            } else {
                Write-Host '  Invalid selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }
        }

        Write-Host ''
        $actionDesc = if ($restore) { "RESTORE to stock vanilla voice" } else { "SWAP to $($selectedModule.Name)" }
        if (-not (Request-HubConfirmation -Prompt "  Confirm: $actionDesc for $($targets.Count) client(s)?")) {
            Write-Host '  Operation cancelled.' -ForegroundColor Yellow
            continue
        }

        $relaunchClients = @()
        foreach ($t in $targets) {
            $ok = Swap-DiscordModule -Client $t -Module $selectedModule -RestoreStock:$restore
            if ($ok) { $relaunchClients += $t }
        }

        Write-Host ''
        Write-Host '  [+] Operations completed.' -ForegroundColor Green
        Write-Host ''

        if ($relaunchClients.Count -gt 0) {
            if (Request-HubConfirmation -Prompt '  Restart Discord client(s) now?') {
                foreach ($t in $relaunchClients) {
                    Write-Host "  [*] Launching $($t.Name)..." -ForegroundColor Cyan
                    Start-DiscordClient -Client $t
                }
            }
        }

        Write-Host ''
        Write-Host '  Press Enter to continue...' -ForegroundColor Gray
        Read-Host | Out-Null
    }
}

function Invoke-DirectRestore {
    [CmdletBinding()]
    param([string]$ClientName = 'All')

    $clients = Get-InstalledDiscordClients
    if ($clients.Count -eq 0) {
        Write-Host '  [!] No installed Discord clients detected.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host '                  RESTORE DISCORD TO STOCK VANILLA VOICE'                       -ForegroundColor Cyan
    Write-Host '===============================================================================' -ForegroundColor Cyan
    Write-Host ''

    $targets = @()
    if (-not $ClientName -or $ClientName -eq 'All') {
        $targets = @($clients)
    } else {
        $targets = @($clients | Where-Object { $_.Name -like "*$ClientName*" })
    }

    if ($targets.Count -eq 0) {
        Write-Host "  [!] No matching Discord clients found for '$ClientName'." -ForegroundColor Yellow
        return
    }

    Write-Host "  Target clients to restore: $($targets.Count)" -ForegroundColor White
    $canRestore = @()
    foreach ($t in $targets) {
        $hasBak = Test-Path -LiteralPath $t.StockBackup
        $bakStatus = if ($hasBak) { '[Stock backup available]' } else { '[No backup found - already stock or unpatched]' }
        Write-Host "    * $($t.Name) ($($t.Version)) - $bakStatus" -ForegroundColor Gray
        if ($hasBak) { $canRestore += $t }
    }
    Write-Host ''

    if ($canRestore.Count -eq 0) {
        Write-Host '  [i] All target clients are already running original stock voice (or have no backups).' -ForegroundColor Yellow
        return
    }

    if (-not (Request-HubConfirmation -Prompt "  Confirm restoring vanilla voice for $($canRestore.Count) client(s)?")) {
        Write-Host '  Operation cancelled.' -ForegroundColor Yellow
        return
    }

    $relaunchClients = @()
    foreach ($t in $canRestore) {
        $ok = Swap-DiscordModule -Client $t -RestoreStock
        if ($ok) { $relaunchClients += $t }
    }

    if ($relaunchClients.Count -gt 0) {
        if (Request-HubConfirmation -Prompt '  Restart Discord client(s) now?') {
            foreach ($t in $relaunchClients) {
                Write-Host "  [*] Launching $($t.Name)..." -ForegroundColor Cyan
                Start-DiscordClient -Client $t
            }
        }
    }
    Write-Host ''
    Write-Host '  [+] Restore operation completed.' -ForegroundColor Green
}

function Invoke-DirectSwap {
    [CmdletBinding()]
    param(
        [string]$ProfileId,
        [string]$ClientName = 'All'
    )

    if (-not $ProfileId) {
        Show-ModuleSwapperMenu
        return
    }

    $modules = Get-AvailableModules
    $match = $null
    foreach ($m in $modules.Values) {
        if ($m.Id -ieq $ProfileId -or $m.Key -eq $ProfileId -or $m.Name -like "*$ProfileId*") {
            $match = $m
            break
        }
    }

    if (-not $match) {
        Write-Host "  [!] Profile '$ProfileId' not found." -ForegroundColor Yellow
        Write-Host '      Available profiles: ' -NoNewline
        Write-Host (($modules.Values | ForEach-Object { $_.Id }) -join ', ') -ForegroundColor Cyan
        return
    }

    $clients = Get-InstalledDiscordClients
    if ($clients.Count -eq 0) {
        Write-Host '  [!] No installed Discord clients detected.' -ForegroundColor Yellow
        return
    }

    $targets = @()
    if (-not $ClientName -or $ClientName -eq 'All') {
        $targets = @($clients)
    } else {
        $targets = @($clients | Where-Object { $_.Name -like "*$ClientName*" })
    }

    if ($targets.Count -eq 0) {
        Write-Host "  [!] No matching Discord clients found for '$ClientName'." -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "  [+] Swapping to profile: $($match.Name)" -ForegroundColor Cyan
    Write-Host "      Target clients: $($targets.Count)" -ForegroundColor White

    if (-not (Request-HubConfirmation -Prompt "  Confirm inject $($match.Name) for $($targets.Count) client(s)?")) {
        Write-Host '  Operation cancelled.' -ForegroundColor Yellow
        return
    }

    $relaunchClients = @()
    foreach ($t in $targets) {
        $ok = Swap-DiscordModule -Client $t -Module $match
        if ($ok) { $relaunchClients += $t }
    }

    if ($relaunchClients.Count -gt 0) {
        if (Request-HubConfirmation -Prompt '  Restart Discord client(s) now?') {
            foreach ($t in $relaunchClients) {
                Write-Host "  [*] Launching $($t.Name)..." -ForegroundColor Cyan
                Start-DiscordClient -Client $t
            }
        }
    }
    Write-Host ''
    Write-Host '  [+] Swap operation completed.' -ForegroundColor Green
}

# ============================================================================
#  DISPATCH
# ============================================================================
switch ($Action) {
    'Menu'    { Show-ModuleSwapperMenu }
    'Swap'    { Invoke-DirectSwap -ProfileId $Profile -ClientName $Client }
    'Restore' { Invoke-DirectRestore -ClientName $Client }
    'List'    {
        Write-Host ''
        Write-Host '  Detected Discord Clients:' -ForegroundColor Yellow
        $clients = Get-InstalledDiscordClients
        foreach ($c in $clients) {
            $hasStock = Test-Path -LiteralPath $c.StockBackup
            $stockTag = if ($hasStock) { '[Stock backup available]' } else { '[Stock active]' }
            Write-Host "    * $($c.Name) (v$($c.Version)) - $stockTag" -ForegroundColor White
            Write-Host "      Path: $($c.VoiceNodePath)" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Available Pre-Compiled Profiles:' -ForegroundColor Yellow
        $modules = Get-AvailableModules
        foreach ($m in $modules.Values) {
            Write-Host "    * [$($m.Key)] $($m.Name) ($($m.Size) bytes)" -ForegroundColor White
        }
        Write-Host ''
    }
    default   { Show-ModuleSwapperMenu }
}
