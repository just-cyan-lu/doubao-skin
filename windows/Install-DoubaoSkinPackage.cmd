@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install Doubao Skin.ps1" %*
if errorlevel 1 goto install_failed

echo.
echo Doubao Skin was installed successfully.
echo Open it from the desktop or Start menu.
if /I "%~1"=="-NoLaunch" exit /b 0
pause
exit /b 0

:install_failed
echo.
echo Doubao Skin installation failed. Review the message above.
pause
exit /b 1
