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
        }
    }

    HyperV = @{
        Host1          = "hyperhost1.domain"
        Host2          = "hyperhost2.domain"   # Target host for LiveMigration
        Cluster        = "HypClusterName"
        ClusterStorage = "C:\ClusterStorage\Volume2"
    }

    Veeam = @{
        BackupRepo = "SN_LocalRepo"
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
        CsvFile   = "D:\Scripts\lotissement.csv"  # CSV of VMs per batch (columns: VMName, Tag)
        OutputCsv = "D:\Scripts\uptime_vm.csv"
        LogDir    = "D:\Scripts\Logs"
    }
}
