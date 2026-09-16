@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Update-CleanBase.ps1" %*
pause
exit /b %errorlevel%
