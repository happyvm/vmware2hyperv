@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM Script post-migration VMware -> Hyper-V (legacy Windows)
REM A executer APRES le premier demarrage de la VM sur Hyper-V.
REM - Si la VM tourne encore sur VMware : aucune action n'est effectuee.
REM - Installe manuellement les Hyper-V Integration Services uniquement pour
REM   les OS legacy (Windows <= 6.1, donc 2003/2008/2008 R2).
REM Exit codes:
REM   0 = succes
REM   1 = erreur
REM   2 = cleanup partiel (fallback force applique)
REM ============================================================================

set "SCRIPT_EXIT_CODE=0"
set "NEED_REBOOT=0"
set "AUTO_REBOOT=1"
set "VMWARE_TOOLS_STATUS=ABSENT"
set "LOG_FILE=C:\temp\vmware2hyperv-postmigration.log"
set "ENABLE_GENERIC_VMWARE_SERVICE_SWEEP=0"
set "ENABLE_HIDDEN_DEVICE_CLEANUP=1"
set "ENABLE_FORCE_VMWARE_CLEANUP=0"
set "OS_VERSION="
set "OS_MAJOR="
set "OS_MINOR="
set "MODEL="

goto :ParseArgs

:ParseArgs
if "%~1"=="" goto :AfterParseArgs
if /i "%~1"=="/noreboot" set "AUTO_REBOOT=0"
if /i "%~1"=="-noreboot" set "AUTO_REBOOT=0"
if /i "%~1"=="/forcecleanup" set "ENABLE_FORCE_VMWARE_CLEANUP=1"
shift
goto :ParseArgs

:AfterParseArgs

call :InitLog
call :Log "Debut du script post-migration VMware -> Hyper-V"

call :RequireAdmin
if errorlevel 1 (
    call :Log "ERREUR : ce script doit etre execute avec des privileges administrateur."
    set "SCRIPT_EXIT_CODE=1"
    goto :EndScript
)

call :GetOSVersion
call :DetectHypervisor
call :Log "Hyperviseur detecte (manufacturer): %MANU%"
call :Log "Modele detecte: %MODEL%"

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

call :UninstallHardwareAgents

if /i "!ENABLE_HIDDEN_DEVICE_CLEANUP!"=="1" (
    call :CleanupHiddenVmwareDevices
)

call :IsIntegrationServicesEligible
if /i not "!IS_ELIGIBLE!"=="1" (
    call :Log "OS non eligible a l'installation Integration Services. Fin sans installation."
    goto :Finalize
)

call :EvaluateIntegrationServicesPresence
if /i "!INSTALL_IS_REQUIRED!"=="1" (
    call :Log "Integration Services incomplets/absents. Installation requise..."

    set "IS_ARCH=x86"
    if defined PROCESSOR_ARCHITEW6432 set "IS_ARCH=x64"
    if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "IS_ARCH=x64"
    if /i "!IS_ARCH!"=="x64" (
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
    call :Log "Integration Services deja presents (services core detectes). Pas d'installation."
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

:RunCommand
set "CMD_TO_RUN=%~1"
call :Log "Execution: !CMD_TO_RUN!"
cmd /c "!CMD_TO_RUN!"
set "CMD_RC=%ERRORLEVEL%"
call :Log "RC=!CMD_RC!"
exit /b !CMD_RC!

:RequireAdmin
net session >nul 2>&1
if errorlevel 1 exit /b 1
exit /b 0

:DetectHypervisor
set "MANU="
set "MODEL="
for /f "tokens=2 delims==" %%A in ('wmic computersystem get manufacturer /value 2^>nul ^| find "="') do set "MANU=%%A"
for /f "tokens=2 delims==" %%A in ('wmic computersystem get model /value 2^>nul ^| find "="') do set "MODEL=%%A"
if not defined MANU (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| findstr /i "SystemManufacturer"') do set "MANU=%%B"
)
if not defined MODEL (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemProductName 2^>nul ^| findstr /i "SystemProductName"') do set "MODEL=%%B"
)
if not defined MANU set "MANU=UNKNOWN"
if not defined MODEL set "MODEL=UNKNOWN"
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
set "VMWARE_PRODUCT_CODE="

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

call :ExtractGuidFromKey "!VMWARE_TOOLS_KEY!"
if defined EXTRACTED_GUID set "VMWARE_PRODUCT_CODE=!EXTRACTED_GUID!"
if not defined VMWARE_PRODUCT_CODE (
    call :ExtractGuidFromCommand "!UNINSTALL_RAW!"
    if defined EXTRACTED_GUID set "VMWARE_PRODUCT_CODE=!EXTRACTED_GUID!"
)
if not defined VMWARE_PRODUCT_CODE (
    call :ExtractGuidFromCommand "!QUIET_UNINSTALL_RAW!"
    if defined EXTRACTED_GUID set "VMWARE_PRODUCT_CODE=!EXTRACTED_GUID!"
)

if defined VMWARE_PRODUCT_CODE (
    set "UNINSTALL_CMD=msiexec /x !VMWARE_PRODUCT_CODE! /qn REBOOT=ReallySuppress /norestart"
    call :Log "Utilisation de msiexec direct pour VMware Tools: !VMWARE_PRODUCT_CODE!"
) else if defined QUIET_UNINSTALL_RAW (
    call :BuildUninstallCommand "!QUIET_UNINSTALL_RAW!"
    if errorlevel 1 (
        set "VMWARE_TOOLS_STATUS=ERROR"
        goto :EOF
    )
    call :Log "Utilisation de QuietUninstallString (normalisee)."
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
call :RunCommand "!UNINSTALL_CMD!"
set "UNINSTALL_RC=!CMD_RC!"
call :Log "Code retour desinstallation VMware Tools: !UNINSTALL_RC!"

if "!UNINSTALL_RC!"=="0" (
    call :Log "Desinstallation VMware Tools terminee avec succes."
    call :VerifyVmwareToolsRemoved
    goto :EOF
)
if "!UNINSTALL_RC!"=="3010" (
    call :Log "Desinstallation VMware Tools succes avec redemarrage requis (3010)."
    set "NEED_REBOOT=1"
    call :VerifyVmwareToolsRemoved
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
if "!ENABLE_FORCE_VMWARE_CLEANUP!"=="1" (
    call :RunVmwareCleanup
) else (
    call :Log "Cleanup force desactive. Aucun fallback agressif applique."
    set "VMWARE_TOOLS_STATUS=ERROR"
)
if /i "!VMWARE_TOOLS_STATUS!"=="CLEANUP_ONLY" (
    set "NEED_REBOOT=1"
)
goto :EOF

:VerifyVmwareToolsRemoved
call :FindVmwareToolsUninstallEntry
if not defined DETECTED_VMWARE_TOOLS_KEY (
    call :Log "Verification post-desinstallation: VMware Tools non detecte dans Add/Remove Programs."
    set "VMWARE_TOOLS_STATUS=SUCCESS"
    goto :EOF
)

call :Log "Verification post-desinstallation: VMware Tools toujours present (cle: !DETECTED_VMWARE_TOOLS_KEY!)."
if "!ENABLE_FORCE_VMWARE_CLEANUP!"=="1" (
    call :Log "Option /forcecleanup active : lancement du cleanup force pour supprimer les residus."
    call :RunVmwareCleanup
) else (
    call :Log "Cleanup force desactive. Relancer avec /forcecleanup pour supprimer l'entree restante."
    set "VMWARE_TOOLS_STATUS=ERROR"
)
if /i "!VMWARE_TOOLS_STATUS!"=="CLEANUP_ONLY" set "NEED_REBOOT=1"
goto :EOF

:FindVmwareToolsUninstallEntry
set "DETECTED_VMWARE_TOOLS_KEY="
set "DETECTED_VMWARE_TOOLS_NAME="
set "DETECTED_VMWARE_TOOLS_PUBLISHER="

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
            if not errorlevel 1 if not defined DETECTED_VMWARE_TOOLS_KEY (
                if not defined CURRENT_PUBLISHER (
                    set "DETECTED_VMWARE_TOOLS_KEY=%%K"
                    set "DETECTED_VMWARE_TOOLS_NAME=!CURRENT_DISPLAY_NAME!"
                    set "DETECTED_VMWARE_TOOLS_PUBLISHER=!CURRENT_PUBLISHER!"
                ) else (
                    echo !CURRENT_PUBLISHER! | findstr /i /c:"VMware" >nul
                    if not errorlevel 1 (
                        set "DETECTED_VMWARE_TOOLS_KEY=%%K"
                        set "DETECTED_VMWARE_TOOLS_NAME=!CURRENT_DISPLAY_NAME!"
                        set "DETECTED_VMWARE_TOOLS_PUBLISHER=!CURRENT_PUBLISHER!"
                    )
                )
            )
        )
    )
)
goto :EOF

:ExtractGuidFromKey
set "RAW_KEY=%~1"
set "EXTRACTED_GUID="
for /f "tokens=2 delims={}" %%G in ("!RAW_KEY!") do (
    if not defined EXTRACTED_GUID (
        echo {%%G} | findstr /r /i /c:"{[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]}" >nul
        if not errorlevel 1 set "EXTRACTED_GUID={%%G}"
    )
)
goto :EOF

:ExtractGuidFromCommand
set "RAW_CMD=%~1"
set "EXTRACTED_GUID="
for /f "tokens=2 delims={}" %%G in ("!RAW_CMD!") do (
    if not defined EXTRACTED_GUID (
        echo {%%G} | findstr /r /i /c:"{[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]}" >nul
        if not errorlevel 1 set "EXTRACTED_GUID={%%G}"
    )
)
goto :EOF

:UninstallHardwareAgents
call :Log "Demarrage desinstallation agents hardware HP/HPE/Dell."

REM Patterns de detection par DisplayName (Publisher verifie si present)
REM HP/HPE
call :UninstallByDisplayName "HP Insight" "HP" "Hewlett"
call :UninstallByDisplayName "HP System Management" "HP" "Hewlett"
call :UninstallByDisplayName "HP ProLiant" "HP" "Hewlett"
call :UninstallByDisplayName "HP iLO" "HP" "Hewlett"
call :UninstallByDisplayName "HPE Agentless" "HPE" "Hewlett"
call :UninstallByDisplayName "HPE Insight" "HPE" "Hewlett"
call :UninstallByDisplayName "HP Array" "HP" "Hewlett"
call :UninstallByDisplayName "Hewlett Packard" "HP" "Hewlett"
REM Dell
call :UninstallByDisplayName "Dell OpenManage" "Dell" ""
call :UninstallByDisplayName "Dell System" "Dell" ""
call :UninstallByDisplayName "Dell BSAFE" "Dell" ""
call :UninstallByDisplayName "iDRAC Service" "Dell" ""
call :UninstallByDisplayName "OpenManage" "Dell" ""

call :Log "Fin desinstallation agents hardware HP/HPE/Dell."
goto :EOF

:UninstallByDisplayName
REM %1 = pattern DisplayName, %2 = pattern Publisher 1, %3 = pattern Publisher 2
set "UBD_PATTERN=%~1"
set "UBD_PUB1=%~2"
set "UBD_PUB2=%~3"
set "UBD_KEY="
set "UBD_NAME="
set "UBD_UNINSTALL_RAW="
set "UBD_QUIET_UNINSTALL_RAW="
set "UBD_UNINSTALL_CMD="

for %%R in (
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
) do (
    for /f "delims=" %%K in ('reg query %%~R 2^>nul ^| findstr /r /c:"HKEY_"') do (
        if not defined UBD_KEY (
            set "UBD_DN="
            set "UBD_PUB="
            for /f "tokens=2,*" %%V in ('reg query "%%K" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do set "UBD_DN=%%W"
            for /f "tokens=2,*" %%V in ('reg query "%%K" /v Publisher 2^>nul ^| findstr /i "Publisher"') do set "UBD_PUB=%%W"

            if defined UBD_DN (
                echo !UBD_DN! | findstr /i /c:"!UBD_PATTERN!" >nul
                if not errorlevel 1 (
                    set "UBD_MATCH_PUB=0"
                    if not defined UBD_PUB set "UBD_MATCH_PUB=1"
                    if defined UBD_PUB (
                        if not "!UBD_PUB1!"=="" (
                            echo !UBD_PUB! | findstr /i /c:"!UBD_PUB1!" >nul
                            if not errorlevel 1 set "UBD_MATCH_PUB=1"
                        )
                        if not "!UBD_PUB2!"=="" if "!UBD_MATCH_PUB!"=="0" (
                            echo !UBD_PUB! | findstr /i /c:"!UBD_PUB2!" >nul
                            if not errorlevel 1 set "UBD_MATCH_PUB=1"
                        )
                    )
                    if "!UBD_MATCH_PUB!"=="1" (
                        set "UBD_KEY=%%K"
                        set "UBD_NAME=!UBD_DN!"
                    )
                )
            )
        )
    )
)

if not defined UBD_KEY goto :EOF

call :Log "Agent detecte: !UBD_NAME! (cle: !UBD_KEY!)"

for /f "tokens=2,*" %%V in ('reg query "!UBD_KEY!" /v QuietUninstallString 2^>nul ^| findstr /i "QuietUninstallString"') do set "UBD_QUIET_UNINSTALL_RAW=%%W"
for /f "tokens=2,*" %%V in ('reg query "!UBD_KEY!" /v UninstallString 2^>nul ^| findstr /i "UninstallString"') do set "UBD_UNINSTALL_RAW=%%W"

if defined UBD_QUIET_UNINSTALL_RAW (
    set "UBD_UNINSTALL_CMD=!UBD_QUIET_UNINSTALL_RAW!"
    call :Log "Utilisation QuietUninstallString."
) else (
    if not defined UBD_UNINSTALL_RAW (
        call :Log "ATTENTION : UninstallString introuvable pour !UBD_NAME!. Ignore."
        goto :EOF
    )
    call :BuildUninstallCommand "!UBD_UNINSTALL_RAW!"
    if errorlevel 1 (
        call :Log "ATTENTION : impossible de construire commande desinstall pour !UBD_NAME!. Ignore."
        goto :EOF
    )
    set "UBD_UNINSTALL_CMD=!UNINSTALL_CMD!"
)

call :RunCommand "!UBD_UNINSTALL_CMD!"
set "UBD_RC=!CMD_RC!"

if "!UBD_RC!"=="0" (
    call :Log "Desinstallation !UBD_NAME! : succes."
) else if "!UBD_RC!"=="3010" (
    call :Log "Desinstallation !UBD_NAME! : succes, reboot requis."
    set "NEED_REBOOT=1"
) else if "!UBD_RC!"=="1605" (
    call :Log "!UBD_NAME! deja absent (MSI 1605)."
) else if "!UBD_RC!"=="1614" (
    call :Log "!UBD_NAME! deja desinstalle (MSI 1614)."
) else (
    call :Log "ATTENTION : echec desinstallation !UBD_NAME! (code !UBD_RC!). Poursuite."
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
    call :Log "ERREUR : uninstall non silencieux detecte. Abandon pour eviter blocage."
    exit /b 1
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

:CleanupHiddenVmwareDevices
set "HIDDEN_VMWARE_CLEANUP_FOUND=0"
set "HIDDEN_VMWARE_CLEANUP_REMOVED=0"

call :Log "Demarrage cleanup des devices caches VMware (post v2v)."

if not defined OS_MAJOR (
    call :Log "ATTENTION : OS_MAJOR inconnu, cleanup devices ignore."
    goto :EOF
)

if !OS_MAJOR! GTR 6 goto :UseModernCleanup
if !OS_MAJOR! EQU 6 if !OS_MINOR! GEQ 4 goto :UseModernCleanup

REM Legacy : devcon (Windows 6.0/6.1 et 5.x)
set "DEVCON_ARCH=x86"
if defined PROCESSOR_ARCHITEW6432 set "DEVCON_ARCH=x64"
if /i "!PROCESSOR_ARCHITECTURE!"=="AMD64" set "DEVCON_ARCH=x64"
set "DEVCON_EXE=C:\temp\HYPERVIS\devcon\!DEVCON_ARCH!\devcon.exe"
if not exist "!DEVCON_EXE!" (
    call :Log "ATTENTION : devcon.exe introuvable, cleanup devices legacy ignore."
    goto :FallbackRegistryCleanup
)

call :Log "Suppression devices VMware via devcon..."
set "DEVCON_CHANGED=0"
"!DEVCON_EXE!" remove @*VMWARE* >nul 2>&1 && set "DEVCON_CHANGED=1"
"!DEVCON_EXE!" remove @*VMware* >nul 2>&1 && set "DEVCON_CHANGED=1"
"!DEVCON_EXE!" remove @*vmware* >nul 2>&1 && set "DEVCON_CHANGED=1"
if "!DEVCON_CHANGED!"=="1" set "NEED_REBOOT=1"
goto :EOF

:UseModernCleanup
set "POWERSHELL_EXE=%SystemRoot%\system32\windowspowershell\v1.0\powershell.exe"
if not exist "!POWERSHELL_EXE!" (
    call :Log "ATTENTION : powershell.exe indisponible, cleanup devices caches ignore."
    goto :EOF
)

for /f "usebackq delims=" %%L in (`"!POWERSHELL_EXE!" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $found=0; $removed=0; $devices=Get-WmiObject Win32_PnPEntity ^| Where-Object { $_.ConfigManagerErrorCode -eq 24 -and (($_.Name -like '*VMware*') -or ($_.Manufacturer -like '*VMware*') -or ($_.PNPDeviceID -like '*VMWARE*')) }; foreach($d in $devices){ $found++; $id=$d.PNPDeviceID; if([string]::IsNullOrWhiteSpace($id)){ continue }; $null = cmd /c ('pnputil /remove-device ' + $id); if($LASTEXITCODE -eq 0){ $removed++ } }; Write-Output ('FOUND=' + $found); Write-Output ('REMOVED=' + $removed)"`) do (
    echo %%L | findstr /b /i "FOUND=" >nul
    if not errorlevel 1 for /f "tokens=2 delims==" %%A in ("%%L") do set "HIDDEN_VMWARE_CLEANUP_FOUND=%%A"
    echo %%L | findstr /b /i "REMOVED=" >nul
    if not errorlevel 1 for /f "tokens=2 delims==" %%A in ("%%L") do set "HIDDEN_VMWARE_CLEANUP_REMOVED=%%A"
)

call :Log "Devices caches VMware detectes: !HIDDEN_VMWARE_CLEANUP_FOUND!"
call :Log "Devices caches VMware supprimes: !HIDDEN_VMWARE_CLEANUP_REMOVED!"
if not "!HIDDEN_VMWARE_CLEANUP_REMOVED!"=="0" (
    set "NEED_REBOOT=1"
)
goto :EOF

:FallbackRegistryCleanup
call :Log "Activation du filet de securite registry CleanupDeviceInstallation."
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v CleanupDeviceInstallation /t REG_DWORD /d 1 /f >nul 2>&1
if errorlevel 1 (
    call :Log "ATTENTION : echec activation CleanupDeviceInstallation."
) else (
    set "NEED_REBOOT=1"
)
goto :EOF

:RunVmwareCleanup
set "VMWARE_CLEANUP_RC=0"
set "VMWARE_REG_ID="
set "VMWARE_MSI_ID="

call :Log "Demarrage cleanup force VMware Tools (fallback uniquement)."

if defined VMWARE_TOOLS_KEY (
    call :Log "Suppression de la cle uninstall VMware Tools detectee initialement."
    call :DeleteRegKey "!VMWARE_TOOLS_KEY!"
)

call :FindVmwareToolsUninstallEntry
if defined DETECTED_VMWARE_TOOLS_KEY (
    call :Log "Suppression de la cle uninstall VMware Tools encore detectee apres echec."
    call :DeleteRegKey "!DETECTED_VMWARE_TOOLS_KEY!"
)

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
REM VMware Tools 9.x / 10.x connus en environnement legacy.
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

call :Log "Code retour cleanup force VMware Tools: !VMWARE_CLEANUP_RC!"
if "!VMWARE_CLEANUP_RC!"=="0" (
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
    set "VMWARE_CLEANUP_RC=1"
)
goto :EOF

:RemoveService
set "SERVICE_NAME=%~1"
if "%SERVICE_NAME%"=="" goto :EOF
sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 goto :EOF
call :Log "Suppression service: %SERVICE_NAME%"
call :GetServiceState "%SERVICE_NAME%"
if /i "!SERVICE_STATE!"=="RUNNING" (
    set "SERVICE_STOPPED=0"
    sc stop "%SERVICE_NAME%" >nul 2>&1
    for /l %%I in (1,1,5) do (
        if "!SERVICE_STOPPED!"=="0" (
            ping -n 2 127.0.0.1 >nul
            call :GetServiceState "%SERVICE_NAME%"
            if /i "!SERVICE_STATE!"=="STOPPED" set "SERVICE_STOPPED=1"
        )
    )
    if /i not "!SERVICE_STATE!"=="STOPPED" (
        call :Log "ATTENTION : timeout arret service %SERVICE_NAME% (etat !SERVICE_STATE!)."
    )
) else (
    call :Log "Service %SERVICE_NAME% deja dans l'etat !SERVICE_STATE!, pas de stop force."
)
sc delete "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    call :Log "ATTENTION : echec suppression service: %SERVICE_NAME%"
    set "VMWARE_CLEANUP_RC=1"
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
    set "VMWARE_CLEANUP_RC=1"
)
goto :EOF

:IsIntegrationServicesEligible
set "IS_ELIGIBLE=0"
if not defined OS_MAJOR (
    call :Log "ERREUR : impossible de determiner la version de l'OS."
    goto :EOF
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

:GetOSVersion
set "OS_VERSION="
set "OS_MAJOR="
set "OS_MINOR="
REM PRIORITE REGISTRY (compatible toutes versions)
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentMajorVersionNumber 2^>nul ^| findstr /i "CurrentMajorVersionNumber"') do set "OS_MAJOR=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentMinorVersionNumber 2^>nul ^| findstr /i "CurrentMinorVersionNumber"') do set "OS_MINOR=%%B"

REM fallback ancienne version
if not defined OS_MAJOR (
    for /f "tokens=2 delims==" %%A in ('wmic os get version /value 2^>nul ^| find "="') do set "OS_VERSION=%%A"
    if defined OS_VERSION (
        for /f "tokens=1,2 delims=." %%A in ("!OS_VERSION!") do (
            set "OS_MAJOR=%%A"
            set "OS_MINOR=%%B"
        )
    )
)
call :Log "Version OS detectee: !OS_MAJOR!.!OS_MINOR!"
goto :EOF

:EvaluateIntegrationServicesPresence
set "INSTALL_IS_REQUIRED=0"
set "IS_MISSING_COMPONENTS="

call :AppendMissingService "vmicheartbeat"
call :AppendMissingService "vmicshutdown"
call :AppendMissingService "vmbus"
call :AppendMissingService "storvsc"
call :AppendMissingService "netvsc"

if defined IS_MISSING_COMPONENTS (
    set "INSTALL_IS_REQUIRED=1"
    call :Log "Composants Integration Services manquants: !IS_MISSING_COMPONENTS!"
) else (
    call :Log "Verification Integration Services: tous les composants core sont presents."
)
goto :EOF

:AppendMissingService
set "AIS_SERVICE=%~1"
if "%AIS_SERVICE%"=="" goto :EOF
sc query "%AIS_SERVICE%" >nul 2>&1
if errorlevel 1 (
    if defined IS_MISSING_COMPONENTS (
        set "IS_MISSING_COMPONENTS=!IS_MISSING_COMPONENTS!,%AIS_SERVICE%"
    ) else (
        set "IS_MISSING_COMPONENTS=%AIS_SERVICE%"
    )
)
goto :EOF

:GetServiceState
set "SERVICE_STATE=UNKNOWN"
set "SERVICE_NAME=%~1"
if "%SERVICE_NAME%"=="" goto :EOF
for /f "tokens=3" %%A in ('sc query "%SERVICE_NAME%" ^| findstr /r /c:"STATE *:"') do set "SERVICE_STATE=%%A"
goto :EOF
