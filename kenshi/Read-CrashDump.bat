@echo off
rem Reads a Kenshi crash dump (crashDump*.zip or a .dmp) and prints where the game crashed.
rem Drag the zip or dmp onto this file, or double-click it to pick the newest crashDump zip in the Kenshi folder.
title Kenshi crash dump
set "PS=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS=pwsh.exe"
mode con cols=160 lines=40 >nul 2>&1
set "F=%~1"
if "%F%"=="" for /f "delims=" %%I in ('dir /b /o-d "%~dp0crashDump*.zip" 2^>nul') do if not defined F set "F=%~dp0%%I"
if "%F%"=="" echo No crash dump given and none found next to this script. Drag a crashDump zip onto this file.
if not "%F%"=="" "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0KenshiConsole.ps1" -DumpFile "%F%"
echo.
pause
