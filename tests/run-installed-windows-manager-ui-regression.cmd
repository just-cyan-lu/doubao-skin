@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0windows-manager-ui-regression.ps1" ^
  -ManagerScript "%LOCALAPPDATA%\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" ^
  -ResultPath "%~dp0..\dist\windows-manager-ui-result.json" ^
  -Iterations 2 ^
  > "%~dp0..\dist\windows-manager-ui-task.log" 2>&1

exit /b %ERRORLEVEL%
