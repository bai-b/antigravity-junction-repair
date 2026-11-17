@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "PS1=%HERE%repair.ps1"

if not exist "%PS1%" goto :nops

set "AUTO="
for %%A in (%*) do if /i "%%~A"=="/auto" set "AUTO=1"

echo Running repair.ps1 ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
echo.
echo [exit code: !RC!]
if not defined AUTO pause
exit /b !RC!

:nops
echo [X] repair.ps1 not found next to this launcher:
echo     %PS1%
echo     Keep repair.ps1 and this .cmd in the same folder.
echo.
pause
exit /b 1
