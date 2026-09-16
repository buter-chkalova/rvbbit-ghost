@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Uninstall-RvbbitGhost.ps1" %*
pause
exit /b %errorlevel%
