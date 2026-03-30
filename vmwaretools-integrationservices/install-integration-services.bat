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

    call :UninstallVmwareTools
    if /i "!VMWARE_TOOLS_STATUS!"=="ERROR" (
        echo ERREUR : la desinstallation de VMware Tools a echoue. Arret du script.
        goto :EOF
    )

    call :IsIntegrationServicesEligible
    if /i not "!IS_ELIGIBLE!"=="1" (
        echo OS non eligible pour l'installation des Integration Services. Fin sans action.
        goto :EOF
    )

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

:UninstallVmwareTools
set "VMWARE_TOOLS_STATUS=ABSENT"
set "VMWARE_TOOLS_KEY="
set "VMWARE_TOOLS_NAME="
set "UNINSTALL_RAW="

for %%R in (
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
) do (
    for /f "delims=" %%K in ('reg query %%~R 2^>nul ^| findstr /r /c:"HKEY_"') do (
        set "CURRENT_DISPLAY_NAME="
        for /f "tokens=2,*" %%V in ('reg query "%%K" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do (
            set "CURRENT_DISPLAY_NAME=%%W"
        )

        if defined CURRENT_DISPLAY_NAME (
            echo !CURRENT_DISPLAY_NAME! | findstr /i "VMware Tools" >nul
            if not errorlevel 1 if not defined VMWARE_TOOLS_KEY (
                set "VMWARE_TOOLS_KEY=%%K"
                set "VMWARE_TOOLS_NAME=!CURRENT_DISPLAY_NAME!"
            )
        )
    )
)

if not defined VMWARE_TOOLS_KEY (
    echo VMware Tools non detecte dans les cles uninstall. Rien a desinstaller.
    goto :EOF
)

echo VMware Tools detecte: "!VMWARE_TOOLS_NAME!"
echo Cle uninstall: !VMWARE_TOOLS_KEY!

for /f "tokens=2,*" %%V in ('reg query "!VMWARE_TOOLS_KEY!" /v UninstallString 2^>nul ^| findstr /i "UninstallString"') do (
    set "UNINSTALL_RAW=%%W"
)

if not defined UNINSTALL_RAW (
    echo ERREUR : UninstallString introuvable pour VMware Tools.
    set "VMWARE_TOOLS_STATUS=ERROR"
    goto :EOF
)

set "UNINSTALL_CMD=!UNINSTALL_RAW!"

echo !UNINSTALL_RAW! | findstr /i "msiexec" >nul
if not errorlevel 1 (
    set "UNINSTALL_CMD=!UNINSTALL_CMD:/I=/X!"
    set "UNINSTALL_CMD=!UNINSTALL_CMD:/i=/X!"
    echo !UNINSTALL_CMD! | findstr /i "/qn" >nul
    if errorlevel 1 set "UNINSTALL_CMD=!UNINSTALL_CMD! /qn"
    echo !UNINSTALL_CMD! | findstr /i "/norestart" >nul
    if errorlevel 1 set "UNINSTALL_CMD=!UNINSTALL_CMD! /norestart"
) else (
    echo !UNINSTALL_RAW! | findstr /i ".msi" >nul
    if not errorlevel 1 (
        set "UNINSTALL_CMD=msiexec /x !UNINSTALL_RAW! /qn /norestart"
    ) else (
        echo !UNINSTALL_CMD! | findstr /i " /S /s /quiet /qn" >nul
        if errorlevel 1 set "UNINSTALL_CMD=!UNINSTALL_CMD! /S"
        echo !UNINSTALL_CMD! | findstr /i "/norestart" >nul
        if errorlevel 1 set "UNINSTALL_CMD=!UNINSTALL_CMD! /norestart"
    )
)

echo Commande de desinstallation executee: !UNINSTALL_CMD!
start /wait "" cmd /c "!UNINSTALL_CMD!"
set "UNINSTALL_RC=!errorlevel!"

echo Code retour desinstallation VMware Tools: !UNINSTALL_RC!
if "!UNINSTALL_RC!"=="0" (
    echo Desinstallation VMware Tools terminee avec succes.
    set "VMWARE_TOOLS_STATUS=SUCCESS"
    goto :EOF
)

if "!UNINSTALL_RC!"=="1605" (
    echo VMware Tools deja absent (code MSI 1605). Aucune action supplementaire.
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :EOF
)

if "!UNINSTALL_RC!"=="1614" (
    echo VMware Tools deja desinstalle (code MSI 1614). Aucune action supplementaire.
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :EOF
)

echo ERREUR : echec de la desinstallation de VMware Tools (code !UNINSTALL_RC!).
set "VMWARE_TOOLS_STATUS=ERROR"
goto :EOF

:IsIntegrationServicesEligible
set "IS_ELIGIBLE=0"
set "OS_VERSION="
for /f "tokens=2 delims==" %%A in ('wmic os get version /value ^| find "="') do set "OS_VERSION=%%A"

if not defined OS_VERSION (
    echo ERREUR : impossible de determiner la version de l'OS.
    goto :EOF
)

for /f "tokens=1,2 delims=." %%A in ("!OS_VERSION!") do (
    set "OS_MAJOR=%%A"
    set "OS_MINOR=%%B"
)

echo Version OS detectee: !OS_VERSION! (major=!OS_MAJOR!, minor=!OS_MINOR!)

if !OS_MAJOR! LSS 6 set "IS_ELIGIBLE=1"
if !OS_MAJOR! EQU 6 if !OS_MINOR! LEQ 1 set "IS_ELIGIBLE=1"

if "!IS_ELIGIBLE!"=="1" (
    echo OS eligible Integration Services (Windows <= 6.1).
) else (
    echo OS non eligible Integration Services (Windows > 6.1).
)
goto :EOF
