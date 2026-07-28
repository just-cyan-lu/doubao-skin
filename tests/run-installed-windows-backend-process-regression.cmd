@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0windows-backend-process-regression.ps1" ^
  -ManagerScript "%LOCALAPPDATA%\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" ^
  -Command activate-library ^
  > "%~dp0..\dist\windows-backend-process-task.log" 2>&1

exit /b %ERRORLEVEL%
