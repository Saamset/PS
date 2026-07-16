@echo off

set SCRIPT=%TEMP%\AuditDeploy.ps1

echo.
echo Telechargement Audit Deploy...
echo.

powershell.exe -ExecutionPolicy Bypass -Command ^
"Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Saamset/PS/PC.ps1' -OutFile '%SCRIPT%'"

if not exist "%SCRIPT%" (
    echo.
    echo ERREUR : impossible de telecharger AuditDeploy.ps1
    pause
    exit /b 1
)

echo.
echo Demarrage Audit Deploy...
echo.

powershell.exe -ExecutionPolicy Bypass -File "%SCRIPT%"