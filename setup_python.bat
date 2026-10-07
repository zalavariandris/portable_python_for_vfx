@echo off
setlocal DisableDelayedExpansion
rem Use Windows PowerShell explicitly; no Python or uv from PATH is used.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set "setup_exit=%errorlevel%"
echo.
pause
exit /b %setup_exit%
