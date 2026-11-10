@echo off
setlocal
title Discord Voice Module Swapper (Instant Drop-In)
color 0B

:: ==============================================================================
::  DISCORD VOICE MODULE SWAPPER -- ZERO COMPILER REQUIRED
::  Instantly swaps pre-compiled stereo & high-gain voice modules into Discord.
::  Includes 1x, 2x, 5x, 10x Gain, 248k, and 1-click Revert to Stock.
:: ==============================================================================

:: Automatically unblock helper scripts if downloaded from the web
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File" >nul 2>&1

if exist "%~dp0lib\Hub-DiscordModules.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-DiscordModules.ps1" -Action Menu
) else (
    echo [!] Error: lib\Hub-DiscordModules.ps1 not found.
    pause
    exit /b 1
)

pause
exit /b %ERRORLEVEL%
