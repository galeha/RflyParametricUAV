@echo off
call "%~dp0rfly-uav.cmd" select %*
exit /b %ERRORLEVEL%
