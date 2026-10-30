@echo off
REM Portable launcher for the Task Dashboard. No install, no admin.
REM -STA is required for WPF; -Bypass is per-process (needs no policy change).
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Dashboard.ps1"
if errorlevel 1 (
  echo.
  echo Dashboard exited with an error. See the message above.
  pause
)
endlocal
