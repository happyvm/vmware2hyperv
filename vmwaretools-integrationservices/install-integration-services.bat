@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM Script post-migration VMware -> Hyper-V (legacy Windows)
REM A executer APRES le premier demarrage de la VM sur Hyper-V.
REM - Si la VM tourne encore sur VMware : aucune action n'est effectuee.
REM - Installe manuellement les Hyper-V Integration Services uniquement pour
REM   les OS legacy (Windows <= 6.1, donc 2003/2008/2008 R2).
REM ============================================================================

set "SCRIPT_EXIT_CODE=0"
set "NEED_REBOOT=0"
set "AUTO_REBOOT=1"
set "VMWARE_TOOLS_STATUS=ABSENT"
set "LOG_FILE=C:\temp\vmware2hyperv-postmigration.log"
set "ENABLE_GENERIC_VMWARE_SERVICE_SWEEP=0"

if /i "%~1"=="/noreboot" set "AUTO_REBOOT=0"
if /i "%~1"=="-noreboot" set "AUTO_REBOOT=0"

call :InitLog
call :Log "Debut du script post-migration VMware -> Hyper-V"

call :RequireAdmin
if errorlevel 1 (
    call :Log "ERREUR : ce script doit etre execute avec des privileges administrateur."
    set "SCRIPT_EXIT_CODE=1"
    goto :EndScript
)

call :DetectHypervisor
call :Log "Hyperviseur detecte (manufacturer): %MANU%"

echo %MANU% | find /i "VMware" >nul
if not errorlevel 1 (
    call :Log "Environnement VMware detecte. Aucune action."
    set "SCRIPT_EXIT_CODE=0"
    goto :EndScript
)

echo %MANU% | find /i "Microsoft" >nul
if errorlevel 1 (
    call :Log "Hyperviseur inconnu. Aucune action."
    set "SCRIPT_EXIT_CODE=0"
    goto :EndScript
)

call :Log "Environnement Hyper-V detecte."
call :UninstallVmwareTools

if /i "!VMWARE_TOOLS_STATUS!"=="ERROR" (
    call :Log "ERREUR : desinstallation VMware Tools en echec."
    set "SCRIPT_EXIT_CODE=1"
    goto :EndScript
)

if /i "!VMWARE_TOOLS_STATUS!"=="CLEANUP_ONLY" (
    call :Log "ATTENTION : cleanup force applique (etat partiel)."
    set "SCRIPT_EXIT_CODE=2"
)

call :IsIntegrationServicesEligible
if /i not "!IS_ELIGIBLE!"=="1" (
    call :Log "OS non eligible a l'installation Integration Services. Fin sans installation."
    goto :Finalize
)

set "HV_SERVICE=vmicheartbeat"
sc query "%HV_SERVICE%" >nul 2>&1
if errorlevel 1 (
    call :Log "Service %HV_SERVICE% absent. Installation des Integration Services..."

    if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
        set "IS_SETUP_EXE=C:\temp\HYPERVIS\amd64\setup.exe"
        call :Log "OS detecte : 64-bit"
    ) else (
        set "IS_SETUP_EXE=C:\temp\HYPERVIS\x86\setup.exe"
        call :Log "OS detecte : 32-bit"
    )

    if not exist "%IS_SETUP_EXE%" (
        call :Log "ERREUR : installeur Integration Services introuvable: %IS_SETUP_EXE%"
        set "SCRIPT_EXIT_CODE=1"
        goto :EndScript
    )

    call :Log "Commande installation Integration Services: \"%IS_SETUP_EXE%\" /quiet /norestart"
    start /wait "" "%IS_SETUP_EXE%" /quiet /norestart
    set "IS_INSTALL_RC=!errorlevel!"
    call :Log "Code retour install Integration Services: !IS_INSTALL_RC!"

    if "!IS_INSTALL_RC!"=="0" (
        set "NEED_REBOOT=1"
    ) else if "!IS_INSTALL_RC!"=="3010" (
        set "NEED_REBOOT=1"
    ) else (
        call :Log "ERREUR : echec installation Integration Services (code !IS_INSTALL_RC!)."
        set "SCRIPT_EXIT_CODE=1"
        goto :EndScript
    )
) else (
    call :Log "Service %HV_SERVICE% deja present. Pas d'installation Integration Services."
)

:Finalize
if "!NEED_REBOOT!"=="1" (
    call :Log "Decision reboot: redemarrage requis."
    if "!AUTO_REBOOT!"=="1" (
        shutdown /r /t 60 /c "Redemarrage automatique apres maintenance VMware Tools / Hyper-V Integration Services"
        if errorlevel 1 (
            call :Log "ATTENTION : impossible de planifier le redemarrage automatiquement."
        ) else (
            call :Log "Redemarrage planifie dans 60 secondes."
        )
    ) else (
        call :Log "Mode /noreboot actif: redemarrage requis mais non declenche automatiquement."
    )
) else (
    call :Log "Decision reboot: aucun redemarrage requis."
)

goto :EndScript

:EndScript
call :Log "Fin du script avec code de sortie %SCRIPT_EXIT_CODE% (statut VMware Tools=%VMWARE_TOOLS_STATUS%, NEED_REBOOT=%NEED_REBOOT%)."
endlocal & exit /b %SCRIPT_EXIT_CODE%

:InitLog
if not exist "C:\temp" mkdir "C:\temp" >nul 2>&1
>>"%LOG_FILE%" echo ============================================================
>>"%LOG_FILE%" echo [%date% %time%] Execution du script install-integration-services.bat
>>"%LOG_FILE%" echo ============================================================
goto :EOF

:Log
set "LOG_MSG=%~1"
echo %LOG_MSG%
>>"%LOG_FILE%" echo [%date% %time%] %LOG_MSG%
goto :EOF

:RequireAdmin
net session >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

:DetectHypervisor
set "MANU="
for /f "tokens=2 delims==" %%A in ('wmic computersystem get manufacturer /value ^| find "="') do set "MANU=%%A"
if not defined MANU set "MANU=UNKNOWN"
goto :EOF

:UninstallVmwareTools
set "VMWARE_TOOLS_STATUS=ABSENT"
set "VMWARE_TOOLS_KEY="
set "VMWARE_TOOLS_NAME="
set "VMWARE_TOOLS_PUBLISHER="
set "UNINSTALL_RAW="
set "QUIET_UNINSTALL_RAW="
set "UNINSTALL_CMD="
set "UNINSTALL_RC="

for %%R in (
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
) do (
    for /f "delims=" %%K in ('reg query %%~R 2^>nul ^| findstr /r /c:"HKEY_"') do (
        set "CURRENT_DISPLAY_NAME="
        set "CURRENT_PUBLISHER="

        for /f "tokens=2,*" %%V in ('reg query "%%K" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do set "CURRENT_DISPLAY_NAME=%%W"
        for /f "tokens=2,*" %%V in ('reg query "%%K" /v Publisher 2^>nul ^| findstr /i "Publisher"') do set "CURRENT_PUBLISHER=%%W"

        if defined CURRENT_DISPLAY_NAME (
            echo !CURRENT_DISPLAY_NAME! | findstr /i /c:"VMware Tools" >nul
            if not errorlevel 1 if not defined VMWARE_TOOLS_KEY (
                if not defined CURRENT_PUBLISHER (
                    set "VMWARE_TOOLS_KEY=%%K"
                    set "VMWARE_TOOLS_NAME=!CURRENT_DISPLAY_NAME!"
                    set "VMWARE_TOOLS_PUBLISHER=!CURRENT_PUBLISHER!"
                ) else (
                    echo !CURRENT_PUBLISHER! | findstr /i /c:"VMware" >nul
                    if not errorlevel 1 (
                        set "VMWARE_TOOLS_KEY=%%K"
                        set "VMWARE_TOOLS_NAME=!CURRENT_DISPLAY_NAME!"
                        set "VMWARE_TOOLS_PUBLISHER=!CURRENT_PUBLISHER!"
                    )
                )
            )
        )
    )
)

if not defined VMWARE_TOOLS_KEY (
    call :Log "VMware Tools non detecte dans les cles uninstall."
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :EOF
)

call :Log "VMware Tools detecte: !VMWARE_TOOLS_NAME!"
if defined VMWARE_TOOLS_PUBLISHER call :Log "Publisher VMware Tools detecte: !VMWARE_TOOLS_PUBLISHER!"
call :Log "Cle uninstall: !VMWARE_TOOLS_KEY!"

for /f "tokens=2,*" %%V in ('reg query "!VMWARE_TOOLS_KEY!" /v QuietUninstallString 2^>nul ^| findstr /i "QuietUninstallString"') do set "QUIET_UNINSTALL_RAW=%%W"
for /f "tokens=2,*" %%V in ('reg query "!VMWARE_TOOLS_KEY!" /v UninstallString 2^>nul ^| findstr /i "UninstallString"') do set "UNINSTALL_RAW=%%W"

if defined QUIET_UNINSTALL_RAW (
    set "UNINSTALL_CMD=!QUIET_UNINSTALL_RAW!"
    call :Log "Utilisation de QuietUninstallString prioritaire."
) else (
    if not defined UNINSTALL_RAW (
        call :Log "ERREUR : UninstallString/QuietUninstallString introuvable pour VMware Tools."
        set "VMWARE_TOOLS_STATUS=ERROR"
        goto :EOF
    )

    call :BuildUninstallCommand "!UNINSTALL_RAW!"
    if errorlevel 1 (
        set "VMWARE_TOOLS_STATUS=ERROR"
        goto :EOF
    )
)

call :Log "Commande desinstallation executee: !UNINSTALL_CMD!"
start /wait "" cmd /c "!UNINSTALL_CMD!"
set "UNINSTALL_RC=!errorlevel!"
call :Log "Code retour desinstallation VMware Tools: !UNINSTALL_RC!"

if "!UNINSTALL_RC!"=="0" (
    call :Log "Desinstallation VMware Tools terminee avec succes."
    set "VMWARE_TOOLS_STATUS=SUCCESS"
    goto :EOF
)
if "!UNINSTALL_RC!"=="3010" (
    call :Log "Desinstallation VMware Tools succes avec redemarrage requis (3010)."
    set "VMWARE_TOOLS_STATUS=SUCCESS"
    set "NEED_REBOOT=1"
    goto :EOF
)
if "!UNINSTALL_RC!"=="1605" (
    call :Log "VMware Tools deja absent (MSI 1605)."
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :EOF
)
if "!UNINSTALL_RC!"=="1614" (
    call :Log "VMware Tools deja desinstalle (MSI 1614)."
    set "VMWARE_TOOLS_STATUS=ABSENT"
    goto :EOF
)

call :Log "Echec desinstallation VMware Tools (code !UNINSTALL_RC!). Tentative cleanup force."
call :RunJasonCleanup
if /i "!VMWARE_TOOLS_STATUS!"=="CLEANUP_ONLY" (
    set "NEED_REBOOT=1"
)
goto :EOF

:BuildUninstallCommand
set "RAW_UNINSTALL=%~1"
set "UNINSTALL_CMD="
set "MSI_GUID="

echo !RAW_UNINSTALL! | findstr /i "msiexec" >nul
if not errorlevel 1 (
    for /f "tokens=2 delims={}" %%G in ("!RAW_UNINSTALL!") do (
        if not defined MSI_GUID set "MSI_GUID={%%G}"
    )

    if defined MSI_GUID (
        set "UNINSTALL_CMD=msiexec /x !MSI_GUID! /qn /norestart"
        call :Log "Desinstallation MSI reconstruite via GUID: !MSI_GUID!"
        exit /b 0
    )

    set "UNINSTALL_CMD=!RAW_UNINSTALL!"
    call :HasSilentSwitch "!UNINSTALL_CMD!"
    if "!HAS_SILENT_SWITCH!"=="0" (
        set "UNINSTALL_CMD=!UNINSTALL_CMD! /qn"
    )
    call :HasNoRestartSwitch "!UNINSTALL_CMD!"
    if "!HAS_NORESTART_SWITCH!"=="0" (
        set "UNINSTALL_CMD=!UNINSTALL_CMD! /norestart"
    )
    exit /b 0
)

echo !RAW_UNINSTALL! | findstr /i ".msi" >nul
if not errorlevel 1 (
    set "UNINSTALL_CMD=msiexec /x ""!RAW_UNINSTALL!"" /qn /norestart"
    call :Log "Desinstallation MSI reconstruite depuis chemin .msi."
    exit /b 0
)

set "UNINSTALL_CMD=!RAW_UNINSTALL!"
call :HasSilentSwitch "!UNINSTALL_CMD!"
if "!HAS_SILENT_SWITCH!"=="0" (
    call :Log "Aucune option silencieuse detectee sur uninstall executable: commande conservee telle quelle."
)
call :HasNoRestartSwitch "!UNINSTALL_CMD!"
if "!HAS_NORESTART_SWITCH!"=="0" set "UNINSTALL_CMD=!UNINSTALL_CMD! /norestart"
exit /b 0

:HasSilentSwitch
set "CHECK_CMD=%~1"
set "HAS_SILENT_SWITCH=0"

echo !CHECK_CMD! | findstr /i " /S" >nul
if not errorlevel 1 set "HAS_SILENT_SWITCH=1"
if "!HAS_SILENT_SWITCH!"=="0" (
    echo !CHECK_CMD! | findstr /i " /s" >nul
    if not errorlevel 1 set "HAS_SILENT_SWITCH=1"
)
if "!HAS_SILENT_SWITCH!"=="0" (
    echo !CHECK_CMD! | findstr /i " /quiet" >nul
    if not errorlevel 1 set "HAS_SILENT_SWITCH=1"
)
if "!HAS_SILENT_SWITCH!"=="0" (
    echo !CHECK_CMD! | findstr /i " /qn" >nul
    if not errorlevel 1 set "HAS_SILENT_SWITCH=1"
)
exit /b 0

:HasNoRestartSwitch
set "CHECK_CMD=%~1"
set "HAS_NORESTART_SWITCH=0"

echo !CHECK_CMD! | findstr /i " /norestart" >nul
if not errorlevel 1 set "HAS_NORESTART_SWITCH=1"
exit /b 0

:RunJasonCleanup
set "JASON_CLEANUP_RC=0"
set "VMWARE_REG_ID="
set "VMWARE_MSI_ID="

call :Log "Demarrage cleanup force VMware Tools (fallback uniquement)."

REM Fallback agressif: nettoyage Installer\Products/Features seulement si
REM la desinstallation standard a echoue.
for /f "delims=" %%K in ('reg query "HKCR\Installer\Products" 2^>nul ^| findstr /r /c:"HKEY_"') do (
    set "CURRENT_PRODUCT_NAME="
    set "CURRENT_PRODUCT_ICON="
    for /f "tokens=2,*" %%A in ('reg query "%%K" /v ProductName 2^>nul ^| findstr /i "ProductName"') do set "CURRENT_PRODUCT_NAME=%%B"

    if defined CURRENT_PRODUCT_NAME (
        echo !CURRENT_PRODUCT_NAME! | findstr /i /c:"VMware Tools" >nul
        if not errorlevel 1 if not defined VMWARE_REG_ID (
            for %%Z in ("%%K") do set "VMWARE_REG_ID=%%~nxZ"
            for /f "tokens=2,*" %%A in ('reg query "%%K" /v ProductIcon 2^>nul ^| findstr /i "ProductIcon"') do set "CURRENT_PRODUCT_ICON=%%B"
            if defined CURRENT_PRODUCT_ICON (
                for /f "tokens=2 delims={}" %%G in ("!CURRENT_PRODUCT_ICON!") do set "VMWARE_MSI_ID=%%G"
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

REM Suppression ciblee des services VMware Tools connus.
call :RemoveService "VMTools"
call :RemoveService "VMUpgradeHelper"
call :RemoveService "VMUSBArbService"
call :RemoveService "VGAuthService"

REM Aucun traitement GISvc par defaut: service non documente ici comme dependance
REM VMware Tools a supprimer. Laisser intact sauf besoin prouve.

if "%ENABLE_GENERIC_VMWARE_SERVICE_SWEEP%"=="1" (
    call :Log "Mode fallback etendu actif: balayage generic des services contenant VMware."
    for /f "delims=" %%S in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services" 2^>nul ^| findstr /r /c:"HKEY_"') do (
        set "CURRENT_SVC_DISPLAY="
        for /f "tokens=2,*" %%A in ('reg query "%%S" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do set "CURRENT_SVC_DISPLAY=%%B"
        if defined CURRENT_SVC_DISPLAY (
            echo !CURRENT_SVC_DISPLAY! | findstr /i /c:"VMware" >nul
            if not errorlevel 1 for %%Z in ("%%S") do call :RemoveService "%%~nxZ"
        )
    )
)

call :DeleteDirectory "C:\Program Files\VMware"
call :DeleteDirectory "C:\Program Files\Common Files\VMware"

call :Log "Code retour cleanup force VMware Tools: !JASON_CLEANUP_RC!"
if "!JASON_CLEANUP_RC!"=="0" (
    set "VMWARE_TOOLS_STATUS=CLEANUP_ONLY"
) else (
    set "VMWARE_TOOLS_STATUS=ERROR"
)
goto :EOF

:DeleteRegKey
set "REG_KEY=%~1"
reg query "%REG_KEY%" >nul 2>&1
if errorlevel 1 goto :EOF
call :Log "Suppression cle registre: %REG_KEY%"
reg delete "%REG_KEY%" /f >nul 2>&1
if errorlevel 1 (
    call :Log "ATTENTION : echec suppression cle registre: %REG_KEY%"
    set "JASON_CLEANUP_RC=1"
)
goto :EOF

:RemoveService
set "SERVICE_NAME=%~1"
if "%SERVICE_NAME%"=="" goto :EOF
sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 goto :EOF
call :Log "Suppression service: %SERVICE_NAME%"
sc stop "%SERVICE_NAME%" >nul 2>&1
sc delete "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    call :Log "ATTENTION : echec suppression service: %SERVICE_NAME%"
    set "JASON_CLEANUP_RC=1"
)
goto :EOF

:DeleteDirectory
set "TARGET_DIR=%~1"
if "%TARGET_DIR%"=="" goto :EOF
if not exist "%TARGET_DIR%" goto :EOF
call :Log "Suppression dossier: %TARGET_DIR%"
rmdir /s /q "%TARGET_DIR%" >nul 2>&1
if errorlevel 1 (
    call :Log "ATTENTION : echec suppression dossier: %TARGET_DIR%"
    set "JASON_CLEANUP_RC=1"
)
goto :EOF

:IsIntegrationServicesEligible
set "IS_ELIGIBLE=0"
set "OS_VERSION="
set "OS_MAJOR="
set "OS_MINOR="
for /f "tokens=2 delims==" %%A in ('wmic os get version /value ^| find "="') do set "OS_VERSION=%%A"

if not defined OS_VERSION (
    call :Log "ERREUR : impossible de determiner la version de l'OS."
    goto :EOF
)

for /f "tokens=1,2 delims=." %%A in ("!OS_VERSION!") do (
    set "OS_MAJOR=%%A"
    set "OS_MINOR=%%B"
)

call :Log "Version OS detectee: !OS_VERSION! (major=!OS_MAJOR!, minor=!OS_MINOR!)"

REM Windows 2003 = 5.x
REM Windows 2008 = 6.0
REM Windows 2008 R2 = 6.1
if !OS_MAJOR! LSS 6 set "IS_ELIGIBLE=1"
if !OS_MAJOR! EQU 6 if !OS_MINOR! LEQ 1 set "IS_ELIGIBLE=1"

if "!IS_ELIGIBLE!"=="1" (
    call :Log "OS eligible Integration Services (Windows <= 6.1)."
) else (
    call :Log "OS non eligible Integration Services (Windows > 6.1)."
)
goto :EOF
