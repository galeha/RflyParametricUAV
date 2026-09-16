@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0rfly-uav.ps1" %*
exit /b %ERRORLEVEL%
