@echo off
rem One-shot report on the current Kenshi logs (or on an archived session folder, drag the folder onto this file).
title Kenshi log analysis
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=50 >nul 2>&1
set "TR="
set /p ANS=Also search the .mod files for who references the missing skeletons/textures? Reads several GB, takes a minute or more. [y/N]: 
if /i "%ANS%"=="y" set "TR=-Trace"
if "%~1"=="" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0KenshiConsole.ps1" -Analyze %TR%
) else (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0KenshiConsole.ps1" -AnalyzeFolder "%~1" %TR%
)
echo.
echo The report is saved in KenshiConsole-data\reports next to this script.
pause
