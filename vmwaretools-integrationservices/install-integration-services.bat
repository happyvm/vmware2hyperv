@echo off
setlocal enabledelayedexpansion

REM ===== Détection de l'hyperviseur =====
for /f "tokens=2 delims==" %%A in ('wmic computersystem get manufacturer /value ^| find "="') do set "MANU=%%A"

echo Manufacturer: %MANU%

echo %MANU% | find /i "VMware" >nul
if not errorlevel 1 (
    echo Environnement VMware detecte. Aucune action.
    goto :EOF
)

echo %MANU% | find /i "Microsoft" >nul
if not errorlevel 1 (
    echo Environnement Hyper-V detecte.

    REM ===== Vérification du service Integration Services =====
    set "HV_SERVICE=vmicheartbeat"
    sc query "%HV_SERVICE%" >nul 2>&1
    if errorlevel 1 (
        echo Service "%HV_SERVICE%" absent. Installation des Integration Services...

        REM ===== Détection architecture OS =====
        if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
            echo OS detecte : 64-bit
            set "IS_SETUP_EXE=C:\temp\HYPERVIS\amd64\setup.exe"
        ) else (
            echo OS detecte : 32-bit
            set "IS_SETUP_EXE=C:\temp\HYPERVIS\x86\setup.exe"
        )

        REM ===== Lancement installation =====
        if not exist "%IS_SETUP_EXE%" (
            echo ERREUR : installeur introuvable : "%IS_SETUP_EXE%"
            goto :EOF
        )

        start /wait "" "%IS_SETUP_EXE%" /quiet /norestart
        echo Code retour installeur : %errorlevel%
    ) else (
        echo Service "%HV_SERVICE%" deja present. Rien a faire.
    )
    goto :EOF
)

echo Hyperviseur inconnu. Aucune action.
goto :EOF
