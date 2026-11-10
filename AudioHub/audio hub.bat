@echo off
setlocal EnableDelayedExpansion
title Ableton Live Audio Control Surface Hub
color 0B

:: ==============================================================================
::  ABLETON LIVE AUDIO CONTROL SURFACE HUB -- HARDENED LAUNCHER
::  This batch file is an unelevated menu shell. All logic lives in
::  narrowly scoped PowerShell helpers under lib\.
::  Automatically unblocks downloaded helper scripts to prevent ExecutionPolicy
::  blocks caused by Windows Mark-of-the-Web.
:: ==============================================================================

:: Automatically unblock helper scripts if downloaded from the web
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File" >nul 2>&1

:MENU
cls
echo ===============================================================================
echo            ABLETON LIVE AUDIO CONTROL SURFACE - UNIVERSAL LAUNCHER
echo ===============================================================================
echo.
echo  [1] Launch Live Audio Hub  (Start Matrix + Ableton Live)
echo  [2] Quick-Restart Audio Engine  (Fix Latency / Glitches)
echo  [3] Open Windows Volume Mixer and Audio Settings
echo  [4] Diagnostic Check: Audio Drivers and Virtual ASIO
echo  [5] Download and Install VB-Audio Matrix  (Secure)
echo  [6] Manage Audio Endpoints  (Rename / Disable / Restore)
echo  [7] VB-Audio Matrix Presets  (Deploy Everything & Routing XML)
echo  [8] Discord Voice Tools    (Module Swapper & C++ Patcher)
echo  [9] Exit
echo.
echo ===============================================================================

set "CHOICE="
set /p "CHOICE=Select an option [1-9]: "

if "!CHOICE!"=="1" goto DO_LAUNCH
if "!CHOICE!"=="2" goto DO_RESTART
if "!CHOICE!"=="3" goto DO_SETTINGS
if "!CHOICE!"=="4" goto DO_DIAGNOSTICS
if "!CHOICE!"=="5" goto DO_DOWNLOAD
if "!CHOICE!"=="6" goto DO_ENDPOINTS
if "!CHOICE!"=="7" goto DO_GENXML
if "!CHOICE!"=="8" goto DO_DISCORD
if "!CHOICE!"=="9" exit /b 0

echo [!] Invalid selection. Please choose 1-9.
timeout /t 2 /nobreak >nul
goto MENU


:DO_LAUNCH
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Launch.ps1" -Action Launch
pause
goto MENU

:DO_RESTART
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Launch.ps1" -Action Restart
pause
goto MENU

:DO_SETTINGS
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Launch.ps1" -Action Settings
pause
goto MENU

:DO_DIAGNOSTICS
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Launch.ps1" -Action Diagnostics
pause
goto MENU

:DO_DOWNLOAD
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Download.ps1"
pause
goto MENU

:DO_ENDPOINTS
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Endpoints.ps1" -Mode Menu
pause
goto MENU

:DO_GENXML
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Launch.ps1" -Action GenerateXml
pause
goto MENU

:DO_DISCORD
cls
echo ===============================================================================
echo                           DISCORD VOICE TOOLS
echo ===============================================================================
echo.
echo  [1] Swap Voice Module  (Instant Drop-In -- Zero Compiler Required)
echo      - Pre-compiled profiles: 1x, 2x, 5x, 10x Gain, 248k, & Safe Revert
echo.
echo  [2] Live Voice Patcher (Advanced C++ Compiler)
echo      - Automatically fetches & compiles custom offsets and patch features
echo.
echo  [3] Revert Discord to Stock (Vanilla Voice)
echo.
echo  [4] Back to Main Menu
echo.
echo ===============================================================================
set "DCHOICE="
set /p "DCHOICE=Select an option [1-4]: "

if "!DCHOICE!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-DiscordModules.ps1" -Action Menu
    pause
    goto DO_DISCORD
)
if "!DCHOICE!"=="2" (
    if exist "%~dp0lib\Discord_voice_node_patcher.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Discord_voice_node_patcher.ps1"
    ) else if exist "%~dp0z Patchers, modules\Discord_voice_node_patcher.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0z Patchers, modules\Discord_voice_node_patcher.ps1"
    ) else (
        echo [!] Error: Discord_voice_node_patcher.ps1 not found.
    )
    pause
    goto DO_DISCORD
)
if "!DCHOICE!"=="3" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-DiscordModules.ps1" -Action Restore
    pause
    goto DO_DISCORD
)
if "!DCHOICE!"=="4" goto MENU

echo [!] Invalid selection. Please choose 1-4.
timeout /t 2 /nobreak >nul
goto DO_DISCORD
