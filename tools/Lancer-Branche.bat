@echo off
rem Telecharge la derniere version d'une branche de TIA Openness Tool depuis GitHub,
rem l'extrait dans %LOCALAPPDATA%\TiaOpennessTool-dev puis lance l'outil (Windows PowerShell 5.1).
rem Sans acces Internet, relance la copie deja presente.
setlocal
set "BRANCH=feat/users-roles"
set "REPO=https://github.com/totomou/TIA-Openness-Tool"
set "DEST=%LOCALAPPDATA%\TiaOpennessTool-dev"

echo.
echo   TIA Openness Tool - branche %BRANCH%
echo   Telechargement de la derniere version...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $zip = Join-Path $env:TEMP 'tia-openness-tool.zip'; Invoke-WebRequest '%REPO%/archive/refs/heads/%BRANCH%.zip' -OutFile $zip -UseBasicParsing; if (Test-Path '%DEST%') { Remove-Item '%DEST%' -Recurse -Force }; Expand-Archive $zip -DestinationPath '%DEST%' -Force; Get-ChildItem '%DEST%' -Recurse | Unblock-File; Remove-Item $zip"
set "DL_ERROR=%ERRORLEVEL%"

set "APP="
for /d %%D in ("%DEST%\TIA-Openness-Tool-*") do set "APP=%%D"

if not defined APP (
    echo.
    echo   ECHEC : telechargement impossible et aucune copie locale.
    echo   Verifiez l'acces a github.com depuis cette machine.
    pause
    exit /b 1
)
if not "%DL_ERROR%"=="0" (
    echo   [!] Telechargement impossible : lancement de la copie locale existante.
    timeout /t 3 >nul
)

echo   Lancement de l'outil...
start "" powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%APP%\scripts\TIA-Openness-Tool.ps1"
endlocal
