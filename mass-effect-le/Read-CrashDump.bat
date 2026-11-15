@echo off
rem Drag a MassEffect1.exe .dmp file onto this file to see the exception and the faulting module.
title Mass Effect crash dump reader
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
if "%~1"=="" (
  echo Drag a .dmp file onto this file.
  pause
  exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0MassEffectConsole.ps1" -DumpFile "%~1"
pause
