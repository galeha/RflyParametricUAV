@echo off
call "%~dp0rfly-uav.cmd" cleanup %*
exit /b %ERRORLEVEL%
