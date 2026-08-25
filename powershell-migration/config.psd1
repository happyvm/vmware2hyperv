@{
    VCenter = @{
        Server = "vcenter.domain.local"
    }

    # ============================================================
    # Precheck configuration (step0-precheck.ps1)
    # ============================================================
    Precheck = @{
        # Path to the input CSV file (vmname;tag columns required)
        InputCsv            = ".\migration_input.csv"

        # Destination folder for CSV files produced by the script
        OutputFolder        = "."

        # Path to a log file. Leave empty to write to the console only.
        LogFile             = ""

        # CSV delimiter used for reading the input file and writing output files
        CsvDelimiter        = ";"

        # Name of the vSphere tag category (Single cardinality, VirtualMachine entity type)
        TagCategoryName     = "MigrationLot"

        # Name of the vCenter custom attribute to read on each VM
        CustomAttributeName = "NB_last_backup"

        # Timeout in seconds granted to VMware Tools to respond during guest operations
        ToolsWaitSecs       = 20

        # Uptime threshold in days: if uptime exceeds this value, UptimeOverThreshold = $true
        UptimeThresholdDays = 45

        # Windows credentials (tried in order; set Enabled = $false to skip an entry)
        # Passwords are never stored here: they are prompted at runtime.
        WindowsCredentials  = @(
            @{ Label = "WIN-LOCAL-ADMIN-01"; UserName = ".\Administrateur"; Enabled = $true  }
            @{ Label = "WIN-LOCAL-ADMIN-02"; UserName = ".\Administrator";  Enabled = $true  }
            @{ Label = "WIN-LOCAL-ADMIN-03"; UserName = ".\admin";          Enabled = $true  }
            @{ Label = "WIN-LOCAL-ADMIN-04"; UserName = ".\adminlocal";     Enabled = $true  }
            @{ Label = "WIN-LOCAL-ADMIN-05"; UserName = ".\adm-local";      Enabled = $true  }
        )

        # Linux credential
        LinuxCredential     = @{ Label = "LINUX-ADMIN-01"; UserName = "root"; Enabled = $true }
    }

    SCVMM = @{
        Server = "scvmm.domain.local"

        # Values below must exactly match existing SCVMM objects
        Network = @{
            PortClassificationName = "PC_VMNetwork"
            LogicalSwitchName      = "LS_SET_VMNetwork"
            # Optional allowlists to limit SCVMM network/subnet discovery to configured objects only.
            # Leave empty arrays to keep the previous discovery behavior.
            AllowedVmNetworkNames  = @()
            AllowedVmSubnetNames   = @()
        }

        # Source OS labels (for example from the batch CSV / CMDB) mapped to exact SCVMM OS names
        OperatingSystemMap = @{
            # Recent Windows versions
            "Windows Server 2025 Datacenter"                   = "Windows Server 2025 Datacenter"
            "Windows Server 2025 Standard"                     = "Windows Server 2025 Standard"
            "Windows Server 2022 Datacenter"                   = "Windows Server 2022 Datacenter"
            "Windows Server 2022 Standard"                     = "Windows Server 2022 Standard"
            "Windows Server 2022 Datacenter Azure Edition"     = "Windows Server 2022 Datacenter"
            "Windows Server 2019 Datacenter"                   = "Windows Server 2019 Datacenter"
            "Windows Server 2019 Standard"                     = "Windows Server 2019 Standard"
            "Windows Server 2016 Datacenter"                   = "Windows Server 2016 Datacenter"
            "Windows Server 2016 Standard"                     = "Windows Server 2016 Standard"
            "Windows Server 2012 R2 Datacenter"                = "Windows Server 2012 R2 Datacenter"
            "Windows Server 2012 R2 Standard"                  = "Windows Server 2012 R2 Standard"
            "Windows Server 2012 Datacenter"                   = "64-bit edition of Windows Server 2012 Datacenter"
            "Windows Server 2012 Standard"                     = "64-bit edition of Windows Server 2012 Standard"

            # 2008
            "Windows Server 2008 R2 Standard"                  = "64-bit edition of Windows Server 2008 R2 Standard"
            "Windows Server 2008 R2 Enterprise"                = "64-bit edition of Windows Server 2008 R2 Enterprise"
            "Windows Server 2008 R2 Datacenter"                = "64-bit edition of Windows Server 2008 R2 Datacenter"
            "Windows Server 2008 Standard"                     = "Windows Server 2008 Standard 32-Bit"
            "Windows Server 2008 Enterprise"                   = "Windows Server 2008 Enterprise 32-Bit"

            # 2003
            "Windows Server 2003 Standard Edition"             = "Windows Server 2003 Standard Edition (32-bit x86)"
            "Windows Server 2003 Enterprise Edition"           = "Windows Server 2003 Enterprise Edition (32-bit x86)"
            "Windows Server 2003 R2 Standard Edition"          = "Windows Server 2003 Standard Edition (32-bit x86)"
            "Windows Server 2003 R2 Enterprise Edition"        = "Windows Server 2003 Enterprise Edition (32-bit x86)"
            "Windows Server 2003 R2 Enterprise x64 Edition"    = "Windows Server 2003 Enterprise x64 Edition"

            # Linux
            #
            # Family defaults: matched on "<distribution> <major version>" when no
            # exact entry above matches. They cover every minor release of a family
            # in one line -- 8.0 through 8.10, listed or not -- because SCVMM only
            # distinguishes the major version anyway. Minor-specific entries below
            # still win, since exact matches are tried first.
            "Red Hat Enterprise Linux 6"                       = "Red Hat Enterprise Linux 6 (64 bit)"
            "Red Hat Enterprise Linux 7"                       = "Red Hat Enterprise Linux 7 (64 bit)"
            "Red Hat Enterprise Linux 8"                       = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 9"                       = "Red Hat Enterprise Linux 9 (64 bit)"

            "Red Hat Enterprise Linux ES 7.9"                  = "Red Hat Enterprise Linux 7 (64 bit)"
            "Red Hat Enterprise Linux ES 7.7"                  = "Red Hat Enterprise Linux 7 (64 bit)"
            "Red Hat Enterprise Linux ES 7.3"                  = "Red Hat Enterprise Linux 7.3 (64 bit)"
            "Red Hat Enterprise Linux 8.10"                    = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 8.9"                     = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 8.8"                     = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 8.7"                     = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 8.3"                     = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 8.0"                     = "Red Hat Enterprise Linux 8 (64 bit)"
            "Red Hat Enterprise Linux 9.4"                     = "Red Hat Enterprise Linux 9 (64 bit)"
            "Red Hat Enterprise Linux ES 6.10"                 = "Red Hat Enterprise Linux 6 (64 bit)"
            "Red Hat Enterprise Linux ES 6.6"                  = "Red Hat Enterprise Linux 6 (64 bit)"
            "CentOS Linux 7"                                   = "CentOS Linux 7 (64 bit)"
            # Same naming pattern as "CentOS Linux 7" above; verify against
            # Get-SCOperatingSystem before relying on it in production.
            "CentOS 6"                                         = "CentOS Linux 6 (64 bit)"

            # ServiceNow cmdb_ci_server short forms: "Windows <year> <edition>"
            # without the word "Server" (Discovery/CMDB "Operating System" field).
            # Targets reuse the exact SCVMM names already validated above.
            "Windows 2025 Datacenter"                          = "Windows Server 2025 Datacenter"
            "Windows 2025 Standard"                            = "Windows Server 2025 Standard"
            "Windows 2022 Datacenter"                          = "Windows Server 2022 Datacenter"
            "Windows 2022 Standard"                            = "Windows Server 2022 Standard"
            "Windows 2019 Datacenter"                          = "Windows Server 2019 Datacenter"
            "Windows 2019 Standard"                            = "Windows Server 2019 Standard"
            "Windows 2016 Datacenter"                          = "Windows Server 2016 Datacenter"
            "Windows 2016 Standard"                            = "Windows Server 2016 Standard"
            "Windows 2012 R2 Datacenter"                       = "Windows Server 2012 R2 Datacenter"
            "Windows 2012 R2 Standard"                         = "Windows Server 2012 R2 Standard"
            "Windows 2012 Datacenter"                          = "64-bit edition of Windows Server 2012 Datacenter"
            "Windows 2012 Standard"                            = "64-bit edition of Windows Server 2012 Standard"
            "Windows 2008 R2 Standard"                         = "64-bit edition of Windows Server 2008 R2 Standard"
            "Windows 2008 R2 Enterprise"                       = "64-bit edition of Windows Server 2008 R2 Enterprise"
            "Windows 2008 R2 Datacenter"                       = "64-bit edition of Windows Server 2008 R2 Datacenter"
            # Also matches "Windows (R) 2008 Standard" once trademark symbols are stripped.
            "Windows 2008 Standard"                            = "Windows Server 2008 Standard 32-Bit"
            "Windows 2008 Standard without Hyper-V"            = "Windows Server 2008 Standard 32-Bit"
            "Windows 2003 Standard"                            = "Windows Server 2003 Standard Edition (32-bit x86)"
            "Windows 2003 Enterprise"                          = "Windows Server 2003 Enterprise Edition (32-bit x86)"

            # ServiceNow cmdb_ci_server splits Linux distribution ("Operating System" =
            # "Linux Red Hat", "Linux CentOS", ...) and version ("OS Version" = "8.10",
            # "7.9.2009", ...) across two columns instead of one self-contained label.
            # CMDB.OsVersionColumns + Merge-CmdbOperatingSystemVersion (lib.ps1) rebuild
            # "<Operating System> <OS Version>" before it reaches this map -- e.g.
            # "Linux Red Hat" + "8.10" -> "Linux Red Hat 8.10", whose family key is
            # "linux red hat 8". These entries are that scheme's family defaults, same
            # targets as the "Red Hat Enterprise Linux <major>" / "CentOS Linux 7"
            # entries above.
            "Linux Red Hat 6"                                  = "Red Hat Enterprise Linux 6 (64 bit)"
            "Linux Red Hat 7"                                  = "Red Hat Enterprise Linux 7 (64 bit)"
            "Linux Red Hat 8"                                  = "Red Hat Enterprise Linux 8 (64 bit)"
            "Linux Red Hat 9"                                  = "Red Hat Enterprise Linux 9 (64 bit)"
            "Linux CentOS 6"                                   = "CentOS Linux 6 (64 bit)"
            "Linux CentOS 7"                                   = "CentOS Linux 7 (64 bit)"

            # Also seen in "Operating System" with a separate "OS Version" (15.6, 8.8,
            # 9.5, 22.04.5, ...) but left unmapped: verify the exact Get-SCOperatingSystem
            # name in your SCVMM before uncommenting -- guessing wrong here fails the OS
            # phase (loudly, with the closest SCVMM names logged) instead of just skipping it.
            # "Linux SuSE 15"     = "SUSE Linux Enterprise Server 15 (64 bit)"
            # "Linux Rocky 8"     = "Rocky Linux 8 (64 bit)"
            # "Linux Rocky 9"     = "Rocky Linux 9 (64 bit)"
            # "Linux Ubuntu 22"   = "Ubuntu Server 22.04 LTS (64 bit)"
            # "Linux Ubuntu 18"   = "Ubuntu Server 18.04 LTS (64 bit)"
        }
    }

    HyperV = @{
        # Default target used when no VMware cluster mapping matches.
        Host1          = "hyperhost1.domain"
        Host2          = "hyperhost2.domain"   # Target host for LiveMigration
        Cluster        = "HypClusterName"
        ClusterStorage = "C:\ClusterStorage\Volume2"
    }

    MigrationMappings = @{
        # Route VMs by source VMware cluster to the correct Hyper-V cluster and CSV volume.
        # Values must match VMware/SCVMM objects exactly. Host1 is used for Instant Recovery,
        # Host2 is used for the LiveMigration validation step.
        ClusterMappings = @(
            @{
                VMwareCluster  = "VmwareClusterA"
                HyperVCluster  = "HypClusterNameA"
                Host1          = "hyperhost-a1.domain"
                Host2          = "hyperhost-a2.domain"
                ClusterStorage = "C:\ClusterStorage\Volume2"
            },
            @{
                VMwareCluster  = "VmwareClusterB"
                HyperVCluster  = "HypClusterNameB"
                Host1          = "hyperhost-b1.domain"
                Host2          = "hyperhost-b2.domain"
                ClusterStorage = "C:\ClusterStorage\Volume3"
            }
        )
    }

    Veeam = @{
        BackupRepo  = "SN_LocalRepo"
        BackupProxy = "" # Optional: Veeam backup proxy name used when creating jobs
    }

    # Centralized timeouts used by the migration pipeline. Values are expressed in
    # seconds so operators no longer need to edit the scripts themselves.
    Timeouts = @{
        Shutdown = @{
            GracefulShutdownSeconds = 300
            ForcedStopGraceSeconds  = 300
        }
        InstantRecovery = @{
            WaitingSeconds = 1800
        }
        LiveMigration = @{
            ValidationSeconds = 600
        }
        Validation = @{
            WinRmConnectionSeconds = 10
            WinRmIdleSeconds       = 60
        }
    }

    Tags = @{
        Category  = "HypV-Migration"           # VMware tag category for migration
        BackupTag = "TAGforbackupsolution"      # Legacy/default tag when no environment is available
        BackupProductionTag    = "TAGforbackupsolution-PROD"
        BackupNonProductionTag = "TAGforbackupsolution-NONPROD"
    }

    # Columns read from the merged CMDB extract and SCVMM custom properties
    # populated during step3. Every value can be overridden in config.local.psd1.
    CMDB = @{
        CsvDelimiter           = ";"
        VmNameColumns          = @("VMName", "Name")
        OperatingSystemColumns = @("OperatingSystem", "Operating system", "Operating System")
        # "OS Version" is where a ServiceNow cmdb_ci_server export puts the version when
        # OperatingSystemColumns only has the family ("Linux Red Hat", "Linux CentOS").
        # Merge-CmdbOperatingSystemVersion (lib.ps1) appends it -- only when the OS label
        # doesn't already carry a version of its own -- before OS mapping resolves it.
        OsVersionColumns       = @("OS Version", "OSVersion", "Version")
        # "Used for" is the environment column name in a ServiceNow cmdb_ci_server export.
        EnvironmentColumns     = @("Environment", "Environnement", "Used for")
        # "Support Level" is the SLA column name in a ServiceNow cmdb_ci_server export
        # (values there are typically "1 - Gold" / "2 - Silver" / "3 - Bronze").
        SlaColumns             = @("SLA", "Sla", "Support Level")
        ApplicationColumns     = @("Application", "ApplicationName", "NomApplication")
        # "DRP Criticality" is the DR criticality column name in a ServiceNow
        # cmdb_ci_server export (values there look like "Level 1 : Major Critical").
        DrpColumns             = @("DRP", "DrpLevel", "DRP Criticality")
        # Column holding which DR mechanism protects the VM (backup product name,
        # replication technology...). Adjust to match your CMDB's actual column name.
        DrpToolColumns         = @("DRP Tool", "DrpTool", "Outil DRP", "Outil de reprise")
        # The three DR mechanisms DrpToolMap values must resolve to.
        DrpToolValues          = @("storage réplication", "VM réplication", "backup restore")
        # Maps a raw CMDB.DrpToolColumns value to one of CMDB.DrpToolValues above.
        # Left empty on purpose: the entries below are illustrative only (public
        # product names, not real CMDB data) -- uncomment and replace with your
        # own CMDB's actual values in config.local.psd1. A CMDB value with no
        # matching key here logs a warning during step3 and leaves the
        # SCVMMCustomProperties.DrpTool property unset for that VM.
        DrpToolMap             = @{
            # "SRDF"        = "storage réplication"   # storage-array replication
            # "Zerto"       = "VM réplication"         # hypervisor-level VM replication
            # "Veeam B&R"   = "backup restore"         # restore from backup
        }
        # Values found in "Used for" seen in practice: Production, Test, Validation,
        # Development, UAT, Pre-Production, Training, Sandbox, Archive, Disaster recovery.
        # Only "production"/"prod" (case-insensitive) count as production; every other
        # non-empty value -- Pre-Production included -- gets Tags.BackupNonProductionTag.
        ProductionValues       = @("production", "prod")
        # Optional finer-grained override of the Production/NonProduction binary
        # above: maps a raw CMDB.EnvironmentColumns value directly to a specific
        # backup tag. When an environment has an entry here, that tag wins outright
        # and ProductionValues/BackupProductionTag/BackupNonProductionTag are not
        # consulted for it. Any environment value with no entry still falls back to
        # the binary split, so leaving this empty (the default) changes nothing.
        # Left empty on purpose: the entries below are illustrative only -- uncomment
        # and replace with your own tag names in config.local.psd1.
        EnvironmentTagMap      = @{
            # "Production"     = "TAGforbackupsolution-PROD"
            # "Pre-Production" = "TAGforbackupsolution-PREPROD"
            # "UAT"            = "TAGforbackupsolution-UAT"
            # "Sandbox"        = "TAGforbackupsolution-NOBACKUP"
        }
    }

    SCVMMCustomProperties = @{
        Environment = "CMDB Environment"
        SLA         = "CMDB SLA"
        Application = "CMDB Application"
        Drp         = "CMDB DRP"
        DrpTool     = "CMDB DRP Tool"
        CreateIfMissing = $true
    }

    Smtp = @{
        Server  = "smtpd.domain"
        # Send-HtmlMail (lib.ps1) forces STARTTLS (EnableSsl); 587 is the submission
        # port. Port 25 only works if the relay accepts STARTTLS on it.
        Port    = 587
        From    = "migrationhyperv-noreply@domain.com"
        Enabled = $true   # Set to $false to disable outgoing email (e.g. pre-migration notifications)
    }

    # Edit email lists before use
    Recipients = @{
        internal   = @("user1@domain", "user2@domain", "user3@domain")
        infogerant = @("user1@domain", "user2@domain", "user3@domain")
    }

    Paths = @{
        Scripts   = "D:\Scripts"
        CsvFile        = "D:\Scripts\batch.csv"   # CSV of VMs per batch (columns: VMName, Tag, OperatingSystem optional)
        ExtractIpCsv   = "D:\Scripts\extract-ip.csv"    # CSV used to map expected IPs (headers: VMName/Name + IP/IPAddress/ExpectedIP)
        CmdbExtractCsv = "D:\Scripts\cmdb_extract.csv"  # Optional CMDB extract used to enrich OS values (headers: VMName/Name and OperatingSystem/Operating system)
        LogDir    = "D:\Scripts\Logs"
    }

    IntegrationServices = @{
        IsoByOsFamily = @{
            "2003" = "D:\ISOs\hyperv-integration-services-2003.iso"
            "2008" = "D:\ISOs\hyperv-integration-services-2008.iso"
        }
    }

    RemoteActions = @{
        WinRm = @{
            # Optional credential for New-PSSession; if omitted, the current user context is used.
            Credential = $null

            # Script uploaded then executed remotely for Windows Server 2012+.
            RemoveVmwareToolsScriptLocalPath  = "D:\Scripts\vmwaretools-integrationservices\install-integration-services.bat"
            RemoveVmwareToolsScriptRemotePath = "C:\Temp\remove-vmware-tools.bat"
        }
    }

    StartVm = @{
        IntegrationPollIntervalSeconds = 30
        IntegrationMaxIterations       = 0   # 0 = unlimited: loop until every VM is compliant (Ctrl+C to stop waiting)
        InventoryBatchThreshold        = 25  # <= threshold: targeted VM lookups; > threshold: one full SCVMM inventory pass
    }

    Orchestrator = @{
        Step3MaxParallelJobs         = 5  # Number of persistent step3 workers
        Step3JobStartupDelaySec      = 2  # Delay between worker starts to smooth SCVMM/Veeam load spikes
        InstantRecoveryStartDelaySec = 2  # Delay between two bulk Instant Recovery starts (step3 phase 1)
    }
}
