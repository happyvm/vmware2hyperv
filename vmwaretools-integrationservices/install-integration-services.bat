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
    set "NEED_REBOOT=0"

    call :UninstallVmwareTools
    if /i "!VMWARE_TOOLS_STATUS!"=="ERROR" (
        echo ERREUR : la desinstallation de VMware Tools a echoue. Arret du script.
        goto :EOF
    )

    if /i "!VMWARE_TOOLS_STATUS!"=="SUCCESS" set "NEED_REBOOT=1"

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
        set "IS_INSTALL_RC=!errorlevel!"
        echo Code retour installeur : !IS_INSTALL_RC!
        if "!IS_INSTALL_RC!"=="0" set "NEED_REBOOT=1"
    ) else (
        echo Service "%HV_SERVICE%" deja present. Rien a faire.
    )

    if "!NEED_REBOOT!"=="1" (
        echo Redemarrage requis (desinstallation VMware Tools et/ou installation Integration Services).
        shutdown /r /t 60 /c "Redemarrage automatique apres maintenance VMware Tools / Hyper-V Integration Services"
        if errorlevel 1 (
            echo ATTENTION : impossible de planifier le redemarrage automatiquement.
        ) else (
            echo Redemarrage planifie dans 60 secondes.
        )
    ) else (
        echo Aucun redemarrage requis.
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
set "JASON_CLEANUP_RC="

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
    goto :RunJasonCleanup
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
    goto :RunJasonCleanup
)

if "!UNINSTALL_RC!"=="1605" (
    echo VMware Tools deja absent (code MSI 1605). Aucune action supplementaire.
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :RunJasonCleanup
)

if "!UNINSTALL_RC!"=="1614" (
    echo VMware Tools deja desinstalle (code MSI 1614). Aucune action supplementaire.
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :RunJasonCleanup
)

echo ERREUR : echec de la desinstallation de VMware Tools (code !UNINSTALL_RC!).
echo Tentative de nettoyage force inspire du script Jason Broestl...

:RunJasonCleanup
set "JASON_CLEANUP_RC=0"
set "VMWARE_REG_ID="
set "VMWARE_MSI_ID="

for /f "delims=" %%K in ('reg query "HKCR\Installer\Products" 2^>nul ^| findstr /r /c:"HKEY_"') do (
    set "CURRENT_PRODUCT_NAME="
    set "CURRENT_PRODUCT_ICON="
    for /f "tokens=2,*" %%A in ('reg query "%%K" /v ProductName 2^>nul ^| findstr /i "ProductName"') do (
        set "CURRENT_PRODUCT_NAME=%%B"
    )

    if defined CURRENT_PRODUCT_NAME (
        echo !CURRENT_PRODUCT_NAME! | findstr /i /c:"VMware Tools" >nul
        if not errorlevel 1 if not defined VMWARE_REG_ID (
            for %%Z in ("%%K") do set "VMWARE_REG_ID=%%~nxZ"
            for /f "tokens=2,*" %%A in ('reg query "%%K" /v ProductIcon 2^>nul ^| findstr /i "ProductIcon"') do (
                set "CURRENT_PRODUCT_ICON=%%B"
            )
            if defined CURRENT_PRODUCT_ICON (
                for /f "tokens=2 delims={}" %%G in ("!CURRENT_PRODUCT_ICON!") do (
                    set "VMWARE_MSI_ID=%%G"
                )
            )
        )
    )
)

if defined VMWARE_REG_ID (
    call :DeleteRegKey "HKCR\Installer\Features\!VMWARE_REG_ID!"
    call :DeleteRegKey "HKCR\Installer\Products\!VMWARE_REG_ID!"
    call :DeleteRegKey "HKLM\SOFTWARE\Classes\Installer\Features\!VMWARE_REG_ID!"
    call :DeleteRegKey "HKLM\SOFTWARE\Classes\Installer\Products\!VMWARE_REG_ID!"
    call :DeleteRegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\!VMWARE_REG_ID!"
)

if defined VMWARE_MSI_ID (
    call :DeleteRegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{!VMWARE_MSI_ID!}"
)

call :DeleteRegKey "HKCR\CLSID\{D86ADE52-C4D9-4B98-AA0D-9B0C7F1EBBC8}"
call :DeleteRegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{9709436B-5A41-4946-8BE7-2AA433CAF108}"
call :DeleteRegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FE2F6A2C-196E-4210-9C04-2B1BC21F07EF}"
call :DeleteRegKey "HKLM\SOFTWARE\VMware, Inc."

for /f "delims=" %%S in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services" 2^>nul ^| findstr /r /c:"HKEY_"') do (
    set "CURRENT_SVC_DISPLAY="
    for /f "tokens=2,*" %%A in ('reg query "%%S" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do (
        set "CURRENT_SVC_DISPLAY=%%B"
    )
    if defined CURRENT_SVC_DISPLAY (
        echo !CURRENT_SVC_DISPLAY! | findstr /i /c:"VMware" >nul
        if not errorlevel 1 (
            for %%Z in ("%%S") do call :RemoveService "%%~nxZ"
        )
    )
)

call :RemoveService "GISvc"

call :DeleteDirectory "C:\Program Files\VMware"
call :DeleteDirectory "C:\Program Files\Common Files\VMware"

echo Code retour nettoyage VMware Tools (batch): !JASON_CLEANUP_RC!

if "!JASON_CLEANUP_RC!"=="0" (
    if /i not "!VMWARE_TOOLS_STATUS!"=="SUCCESS" set "VMWARE_TOOLS_STATUS=SUCCESS"
    goto :EOF
)

echo ERREUR : le nettoyage Jason a echoue.
set "VMWARE_TOOLS_STATUS=ERROR"
goto :EOF

:DeleteRegKey
set "REG_KEY=%~1"
reg query "%REG_KEY%" >nul 2>&1
if errorlevel 1 goto :EOF
echo Suppression cle registre: %REG_KEY%
reg delete "%REG_KEY%" /f >nul 2>&1
if errorlevel 1 (
    echo ATTENTION : echec suppression cle registre: %REG_KEY%
)
goto :EOF

:RemoveService
set "SERVICE_NAME=%~1"
if "%SERVICE_NAME%"=="" goto :EOF
sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 goto :EOF
echo Suppression service: %SERVICE_NAME%
sc stop "%SERVICE_NAME%" >nul 2>&1
sc delete "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo ATTENTION : echec suppression service: %SERVICE_NAME%
)
goto :EOF

:DeleteDirectory
set "TARGET_DIR=%~1"
if "%TARGET_DIR%"=="" goto :EOF
if not exist "%TARGET_DIR%" goto :EOF
echo Suppression dossier: %TARGET_DIR%
rmdir /s /q "%TARGET_DIR%" >nul 2>&1
if errorlevel 1 (
    echo ATTENTION : echec suppression dossier: %TARGET_DIR%
)
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
REM Windows 2003 = 5.x
REM Windows 2008 = 6.0
REM Windows 2008 R2 = 6.1

if !OS_MAJOR! LSS 6 set "IS_ELIGIBLE=1"
if !OS_MAJOR! EQU 6 if !OS_MINOR! LEQ 1 set "IS_ELIGIBLE=1"

if "!IS_ELIGIBLE!"=="1" (
    echo OS eligible Integration Services (Windows <= 6.1).
) else (
    echo OS non eligible Integration Services (Windows > 6.1).
)
goto :EOF
