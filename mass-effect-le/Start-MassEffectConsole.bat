@echo off
rem Mass Effect Console launcher. Double-click, then start Mass Effect (before or after, either works).
rem Extra options pass straight through, e.g.:  Start-MassEffectConsole.bat -MinLevel Warn
title Mass Effect Console
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=50 >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0MassEffectConsole.ps1" %*
echo.
echo Console closed. Press any key to close this window.
pause >nul
