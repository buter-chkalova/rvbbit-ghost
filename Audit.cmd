@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Audit-RvbbitGhost.ps1" %*
pause
exit /b %errorlevel%
