@echo off
rem OPTIONAL, run once. Tells Windows to write a small crash dump (.dmp) into the console's data\dumps folder
rem whenever MassEffect1.exe crashes. Without it an engine crash leaves no evidence beyond the Windows event.
rem Writes ONE registry key (HKLM ...\Windows Error Reporting\LocalDumps\MassEffect1.exe). Needs administrator.
rem Undo:  Enable-CrashDumps.bat remove
net session >nul 2>&1
if errorlevel 1 (
  echo This needs administrator rights. Asking Windows for them...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)
set "KEY=HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\MassEffect1.exe"
if /i "%~1"=="remove" (
  reg delete "%KEY%" /f
  echo Removed. Windows no longer saves dumps for MassEffect1.exe.
  pause
  exit /b
)
echo This will create the registry key:
echo   %KEY%
echo with: DumpFolder = %~dp0data\dumps , DumpType = 1 (mini dump), DumpCount = 5.
set /p ANS=Go ahead? [y/N]: 
if /i not "%ANS%"=="y" exit /b
if not exist "%~dp0data\dumps" mkdir "%~dp0data\dumps"
reg add "%KEY%" /v DumpFolder /t REG_EXPAND_SZ /d "%~dp0data\dumps" /f
reg add "%KEY%" /v DumpType /t REG_DWORD /d 1 /f
reg add "%KEY%" /v DumpCount /t REG_DWORD /d 5 /f
echo.
echo Done. The next MassEffect1.exe crash writes a .dmp there and the console reads it in its post-mortem.
pause
