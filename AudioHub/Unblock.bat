@echo off
setlocal
title Unblock AudioHub Files
color 0A
echo ===============================================================================
echo            UNBLOCKING AUDIOHUB FILES (Removing Mark-of-the-Web)
echo ===============================================================================
echo.
echo Unblocking all files and subdirectories...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File; Write-Host '  [+] All files in %~dp0 unblocked successfully.' -ForegroundColor Green"
echo.
echo You can now run audio hub.bat or Rename VB.bat without Windows blocking them.
echo.
pause
