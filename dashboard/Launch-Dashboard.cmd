@echo off
REM Portable launcher for the Task Dashboard. No install, no admin.
REM 1) Strip the "mark of the web" from the files so downloaded scripts don't
REM    prompt a Security warning per file (needed because Group Policy can set
REM    the execution policy to Unrestricted, which overrides -ExecutionPolicy).
REM 2) Launch the WPF app. -STA is required for WPF.
setlocal
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Dashboard.ps1"
if errorlevel 1 (
  echo.
  echo Dashboard exited with an error. See the message above.
  pause
)
endlocal
