@echo off
rem One-shot report on the current ME1 logs (or on an archived session folder: drag the folder onto this file).
title Mass Effect log analysis
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=50 >nul 2>&1
if "%~1"=="" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0MassEffectConsole.ps1" -Analyze
) else (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0MassEffectConsole.ps1" -AnalyzeFolder "%~1"
)
echo.
echo The report is saved in the data\reports folder next to this script.
pause
