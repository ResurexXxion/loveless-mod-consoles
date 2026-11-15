@echo off
rem Kenshi Console launcher. Double-click, then start Kenshi (before or after, either works).
rem Extra options pass straight through, e.g.:  Start-KenshiConsole.bat -MinLevel Warn
title Kenshi Console
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=50 >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0KenshiConsole.ps1" %*
echo.
echo Console closed. Press any key to close this window.
pause >nul
