@echo off
setlocal
title Rvbbit Ghost disposable session
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-RvbbitGhost.ps1" %*
pause
exit /b %errorlevel%
