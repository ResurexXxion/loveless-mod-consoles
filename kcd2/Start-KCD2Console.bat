@echo off
rem KCD2 Console launcher. Double-click, then start the game (before or after, either works).
rem Extra options pass straight through, e.g.:  Start-KCD2Console.bat -MinLevel Warn
title KCD2 Console
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=50 >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0KCD2Console.ps1" %*
echo.
echo Console closed. Press any key to close this window.
pause >nul
