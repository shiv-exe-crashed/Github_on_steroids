@echo off
rem Windows setup for gh-desktop-profiles. Double-click this file, or run it in a terminal.
rem It starts the guided setup (a menu if you already have profiles).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\ghdp.ps1" setup
echo.
pause
