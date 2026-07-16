@echo off

set SCRIPT=%TEMP%\ps.ps1

echo.
echo Telechargement du script
echo.

powershell.exe -ExecutionPolicy Bypass -Command ^
"Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Saamset/PS/ps.ps1' -OutFile '%SCRIPT%'"

if not exist "%SCRIPT%" (
    echo.
    echo ERREUR : impossible de telecharger le script
    pause
    exit /b 1
)

echo.
echo Demarrage du script de déploiement
echo.

powershell.exe -ExecutionPolicy Bypass -File "%SCRIPT%"
