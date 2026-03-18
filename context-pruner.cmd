@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PWSH_EXE="

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 set "PWSH_EXE=pwsh"

if not defined PWSH_EXE (
  where powershell >nul 2>nul
  if %ERRORLEVEL%==0 set "PWSH_EXE=powershell"
)

if not defined PWSH_EXE (
  echo No usable PowerShell executable was found on this host. 1>&2
  exit /b 127
)

"%PWSH_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%context-pruner.ps1" %*
exit /b %ERRORLEVEL%
