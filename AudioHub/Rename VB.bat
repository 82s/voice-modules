@echo off
setlocal
title VB-Audio Matrix Endpoint Manager
color 0B

:: ==============================================================================
::  VB-Audio Matrix Endpoint Manager -- Hardened Launcher
::  Opens the Preview / Apply / Restore sub-menu.
::  Runs UNELEVATED. Elevation is requested only when Apply or Restore is
::  selected from the sub-menu -- and only for the exact registry operations.
::  Automatically unblocks downloaded helper scripts.
:: ==============================================================================

:: Automatically unblock helper scripts if downloaded from the web
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\Hub-Endpoints.ps1" -Mode Menu

pause
exit /b %ERRORLEVEL%