@{
    VCenter = @{
        Server = "vcenter.domain.local"
    }

    SCVMM = @{
        Server = "scvmm.domain.local"

        # Les valeurs ci-dessous doivent correspondre exactement aux objets SCVMM existants
        Network = @{
            PortClassificationName = "PC_VMNetwork"
            LogicalSwitchName      = "LS_SET_VMNetwork"
        }
    }

    HyperV = @{
        Host1          = "hyperhost1.domain"
        Host2          = "hyperhost2.domain"   # Serveur cible pour la LiveMigration
        Cluster        = "HypClusterName"
        ClusterStorage = "C:\ClusterStorage\Volume2"
    }

    Veeam = @{
        BackupRepo = "SN_LocalRepo"
    }

    Tags = @{
        Category  = "HypV-Migration"           # Catégorie de tag VMware pour la migration
        BackupTag = "TAGforbackupsolution"      # Tag appliqué aux VMs après migration
    }

    Smtp = @{
        Server = "smtpd.domain"
        Port   = 25
        From   = "migrationhyperv-noreply@domain.com"
    }

    # Modifier les listes d'emails avant utilisation
    Recipients = @{
        internal   = @("user1@domain", "user2@domain", "user3@domain")
        infogerant = @("user1@domain", "user2@domain", "user3@domain")
    }

    Paths = @{
        Scripts   = "D:\Scripts"
        CsvFile   = "D:\Scripts\lotissement.csv"  # CSV des VMs par lot (colonnes: VMName, Tag)
        OutputCsv = "D:\Scripts\uptime_vm.csv"
        LogDir    = "D:\Scripts\Logs"
    }
}
