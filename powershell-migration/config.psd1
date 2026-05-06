@{
    VCenter = @{
        Server = "vcenter.domain.local"
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
            # Windows récents
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
        }
    }

    HyperV = @{
        Host1          = "hyperhost1.domain"
        Host2          = "hyperhost2.domain"   # Target host for LiveMigration
        Cluster        = "HypClusterName"
        ClusterStorage = "C:\ClusterStorage\Volume2"
    }

    Veeam = @{
        BackupRepo  = "SN_LocalRepo"
        BackupProxy = "" # Optional: Veeam backup proxy name used when creating jobs
    }

    Tags = @{
        Category  = "HypV-Migration"           # VMware tag category for migration
        BackupTag = "TAGforbackupsolution"      # Tag applied to VMs after migration
    }

    Smtp = @{
        Server = "smtpd.domain"
        Port   = 25
        From   = "migrationhyperv-noreply@domain.com"
    }

    # Edit email lists before use
    Recipients = @{
        internal   = @("user1@domain", "user2@domain", "user3@domain")
        infogerant = @("user1@domain", "user2@domain", "user3@domain")
    }

    Paths = @{
        Scripts   = "D:\Scripts"
        CsvFile        = "D:\Scripts\lotissement.csv"   # CSV of VMs per batch (columns: VMName, Tag, OperatingSystem optional)
        ExtractIpCsv   = "D:\Scripts\extract-ip.csv"    # CSV used to map expected IPs (headers: VMName/Name + IP/IPAddress/ExpectedIP)
        CmdbExtractCsv = "D:\Scripts\cmdb_extract.csv"  # Optional CMDB extract used to enrich OS values (headers: VMName/Name and OperatingSystem/Operating system)
        OutputCsv      = "D:\Scripts\uptime_vm.csv"
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
        IntegrationMaxIterations       = 10
    }

    Orchestrator = @{
        Step3MaxParallelJobs    = 5  # Number of persistent step3 workers
        Step3JobStartupDelaySec = 2  # Delay between worker starts to smooth SCVMM/Veeam load spikes
    }
}
