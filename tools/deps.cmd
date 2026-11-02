@echo off
rem Windows: runs tools\deps.ps1 even where PowerShell scripts are blocked.
rem usage: tools\deps.cmd [-Check] [-Distro Ubuntu]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deps.ps1" %*
exit /b %ERRORLEVEL%
