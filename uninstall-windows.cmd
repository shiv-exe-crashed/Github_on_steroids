@echo off
rem Removes everything gh-desktop-profiles made on Windows (it asks first).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\ghdp.ps1" uninstall
echo.
pause
