@echo off
setlocal
title Discord Voice Module Patcher (Stereo & High Bitrate)
color 0B

:: ==============================================================================
::  DISCORD VOICE MODULE PATCHER -- STEREO & HIGH BITRATE UNLOCKER
::  Enables 48kHz, 384kbps bitrate, true stereo voice input, and filter bypass.
::  Automatically unblocks downloaded helper scripts.
:: ==============================================================================

:: Automatically unblock helper scripts if downloaded from the web
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File" >nul 2>&1

if exist "%~dp0lib\Discord_voice_node_patcher.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Discord_voice_node_patcher.ps1" %*
) else if exist "%~dp0z Patchers, modules\Discord_voice_node_patcher.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0z Patchers, modules\Discord_voice_node_patcher.ps1" %*
) else (
    echo [!] Error: Discord_voice_node_patcher.ps1 not found.
    pause
    exit /b 1
)

pause
exit /b %ERRORLEVEL%
