@echo off
call "%~dp0rfly-uav.cmd" select -WaitForKeyCleanup %*
exit /b %ERRORLEVEL%
