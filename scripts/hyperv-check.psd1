# hyperv-check.psd1
# Configuration file for Test-HyperVNodeReadiness.ps1
#
# Copy this file next to the script (or specify -ConfigFile <path>).
# Any value left empty ('') will be prompted interactively at runtime.
#
# Required: Mode, StorageType
# Optional: everything else (omit or set to '' to skip that section)

@{
    # ── General ───────────────────────────────────────────────────────────────
    # PreNode     — validate this machine as a standalone Hyper-V host
    # PreCluster  — validate this machine + remote nodes for failover clustering
    # Both        — run all checks (recommended)
    Mode        = 'Both'

    # SAN — external shared storage via iSCSI or Fibre Channel (MPIO required)
    # S2D — Storage Spaces Direct, internal disks, Datacenter edition required
    StorageType = 'SAN'

    # Live Migration authentication target.
    # Kerberos — validate SPNs and constrained delegation between nodes (recommended).
    # CredSSP  — do not require Kerberos constrained delegation; warn if CredSSP is not enabled.
    LiveMigrationAuth = 'Kerberos'

    # ── Platform security requirements ────────────────────────────────────────
    # Leave these disabled ($false) to record the current state as INFO only.
    # Enable a requirement to turn a missing/disabled control into WARN/FAIL.
    RequireSecureBoot = $false
    RequireTpm        = $false
    RequireBitLocker  = $false
    RequireVbs        = $false
    RequireHvci       = $false

    # ── Cluster nodes ─────────────────────────────────────────────────────────
    # FQDNs or IPs of the OTHER nodes (this local node is always included).
    # Leave empty for single-node / PreNode validation.
    ClusterNodes = @(
        # 'node2.corp.local'
        # 'node3.corp.local'
    )

    # Planned NetBIOS name of the cluster (used for prestaged CNO check).
    # Leave empty to skip.
    ClusterName  = ''    # e.g. 'CLHYPERV01'

    # ── Active Directory ──────────────────────────────────────────────────────
    # OU Distinguished Name where CNO and VCO computer objects will be created.
    # Leave empty to skip section J (OU permission checks).
    ClusterOU = ''    # e.g. 'OU=Clusters,OU=Servers,DC=corp,DC=local'

    # SAMAccountName (with or without domain prefix) of the service/admin account
    # used to create and manage the cluster.
    # Leave empty to skip local-admin and OU ACL checks.
    ServiceAccount = ''    # e.g. 'CORP\svc_cluster'  or  'svc_cluster'

    # ── Quorum / Witness ──────────────────────────────────────────────────────
    # UNC path of the file share witness.
    # Required for even-node clusters (2, 4, ... nodes).
    # Leave empty to skip witness connectivity check.
    WitnessShare = ''    # e.g. '\\fileserver01\clusterwitness'

    # ── Infrastructure endpoints (port connectivity checks) ───────────────────
    # Domain controllers to test LDAP / Kerberos / DNS / SMB ports against.
    # If left empty the script auto-discovers up to 3 DCs via DirectoryServices.
    DomainControllers = @(
        # 'dc01.corp.local'
        # 'dc02.corp.local'
    )

    # iSCSI target portals (SAN mode only).
    # Leave empty to skip iSCSI port check.
    IscsiTargets = @(
        # 'san01.corp.local'
        # '10.0.10.50'
    )

    # Dedicated NTP server. Leave empty to skip NTP UDP port check.
    # (DCs are also checked for NTP by default in the DC port loop above.)
    NtpServer = ''    # e.g. 'ntp.corp.local'  or  '192.168.1.1'

    # SCVMM server FQDN/IP. Leave empty to skip.
    ScvmmServer = ''    # e.g. 'scvmm01.corp.local'

    # ── Report options ────────────────────────────────────────────────────────
    # Log file path. Leave empty to auto-generate with timestamp in CWD.
    LogFile = ''    # e.g. 'C:\Logs\HyperV-Readiness.log'

    # HTML report path. Leave empty to skip HTML output.
    HtmlReportPath = ''    # e.g. 'C:\Reports\readiness.html'

    # Set to $true to skip the long-running Test-Cluster validation wizard.
    SkipClusterValidation = $false
}
