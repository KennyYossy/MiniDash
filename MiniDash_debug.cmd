@echo off
echo MiniDash test run. Error messages will show here.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0MiniDash.ps1"
echo.
echo ---- log ----
type "%APPDATA%\MiniDash\error.log"
pause
