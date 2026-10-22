@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RemoteCodex.ps1" -Action Setup
pause
