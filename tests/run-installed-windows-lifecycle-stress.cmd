@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0windows-lifecycle-regression.ps1" ^
  -ManagerScript "%LOCALAPPDATA%\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" ^
  -ResultPath "%~dp0..\dist\windows-installed-lifecycle-stress-result.json" ^
  -Iterations 5 ^
  > "%~dp0..\dist\windows-installed-lifecycle-stress-task.log" 2>&1

exit /b %ERRORLEVEL%
