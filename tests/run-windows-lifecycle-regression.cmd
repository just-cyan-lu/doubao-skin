@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0windows-lifecycle-regression.ps1" ^
  > "%~dp0..\dist\windows-lifecycle-task.log" 2>&1

exit /b %ERRORLEVEL%
