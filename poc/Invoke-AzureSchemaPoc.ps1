#Requires -Version 7.2
<#
Creates TWO disposable Azure PostgreSQL16 servers and deletes its dedicated RG in finally.
No existing server, firewall or database is modified. Requires az, psql, pg_dump.
Passwords are generated per run, never logged or persisted in repository files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$Location = 'koreacentral',
    [string]$Sku = 'Standard_B2s',
    [ValidateSet('Burstable','GeneralPurpose')][string]$Tier = 'Burstable',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot ('runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
. "$PSScriptRoot/Common.ps1"
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$runId = (Get-Date -Format 'yyMMddHHmmss') + [Guid]::NewGuid().ToString('N').Substring(0,4)
$resourceGroup = "rg-pg-schema-poc-$runId"
$sourceName = "pg-schema-src-$runId"
$targetName = "pg-schema-tgt-$runId"
$admin = 'pocadmin'
$adminPassword = 'A9!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$replicationPassword = 'R9!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$redactionSecrets = @($adminPassword, $replicationPassword)
$createdGroup = $false
$runError = $null
$cleanupError = $null
$report = [ordered]@{
    runId = $runId; startedUtc = [DateTime]::UtcNow.ToString('o'); status = 'running'
    subscriptionId = $SubscriptionId; location = $Location; resourceGroup = $resourceGroup
    source = $sourceName; target = $targetName; version = '16'; sku = $Sku
    cleanup = 'not-created'; firewall = [Collections.Generic.List[object]]::new()
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path

function Save-RunReport {
    $report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDirectory 'deployment.json') -Encoding utf8
}

function Invoke-PocAz([string[]]$Arguments) {
    $text = (& az @Arguments --subscription $SubscriptionId --only-show-errors 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw (Protect-PocText "Azure CLI failed: $text" $redactionSecrets) }
    Protect-PocText $text $redactionSecrets
}

try {
    foreach ($command in @('az','psql','pg_dump')) { Get-Command $command -ErrorAction Stop | Out-Null }
    $accountId = (& az account show --query id -o tsv --only-show-errors | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $accountId -ne $SubscriptionId) { throw 'Azure CLI active subscription must match SubscriptionId. No resources created.' }
    $clientIp = [string](Invoke-RestMethod 'https://api.ipify.org')
    $parsedIp = [Net.IPAddress]::Parse($clientIp)
    if ($parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'An IPv4 client address is required.' }
    $exists = Invoke-PocAz @('group','exists','--name',$resourceGroup,'-o','tsv')
    if ($exists -ne 'false') { throw 'Refusing to reuse an existing resource group.' }
    # Mark cleanup intent before create: a partial/timeout response may still create the RG.
    $createdGroup = $true
    Invoke-PocAz @('group','create','--name',$resourceGroup,'--location',$Location,
        '--tags',"purpose=schema-replication-poc","runId=$runId",'disposable=true','-o','none') | Out-Null
    $report.cleanup = 'pending'
    Save-RunReport
    foreach ($serverName in @($sourceName, $targetName)) {
        Write-Host "Provisioning $serverName ($Sku, PostgreSQL16, $Location)"
        # Use an in-memory ARM request so no password appears in process arguments/files.
        $accessToken = Invoke-PocAz @('account','get-access-token','--resource','https://management.azure.com/',
            '--query','accessToken','-o','tsv')
        $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
        $accessToken = $null
        $body = @{
            location = $Location; sku = @{ name = $Sku; tier = $Tier }
            tags = @{ purpose = 'schema-replication-poc'; runId = $runId }
            properties = @{
                createMode = 'Create'; version = '16'
                administratorLogin = $admin; administratorLoginPassword = $adminPassword
                storage = @{ storageSizeGB = 32; autoGrow = 'Disabled'; type = 'Premium_LRS' }
                backup = @{ backupRetentionDays = 7; geoRedundantBackup = 'Disabled' }
                highAvailability = @{ mode = 'Disabled' }
                network = @{ publicNetworkAccess = 'Enabled' }
            }
        } | ConvertTo-Json -Depth 8
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.DBforPostgreSQL/flexibleServers/${serverName}?api-version=2024-08-01"
        Invoke-RestMethod -Method Put -Uri $uri -Authentication Bearer -Token $secureToken `
            -ContentType 'application/json' -Body $body -Verbose:$false -Debug:$false | Out-Null
        $body = $null; $secureToken = $null
    }
    # Both ARM creations are now in flight; configure each server once ready.
    foreach ($serverName in @($sourceName, $targetName)) {
        Invoke-PocAz @('postgres','flexible-server','wait','-g',$resourceGroup,'-n',$serverName,
            '--custom',"state=='Ready'",'--timeout','1800','-o','none') | Out-Null
        Invoke-PocAz @('postgres','flexible-server','firewall-rule','create','-g',$resourceGroup,'-n',$serverName,
            '--rule-name','local-test-client','--start-ip-address',$clientIp,'--end-ip-address',$clientIp,'-o','none') | Out-Null
        $report.firewall.Add(@{ server = $serverName; purpose = 'local-test-client'; ip = $clientIp })
        Invoke-PocAz @('postgres','flexible-server','parameter','set','-g',$resourceGroup,'-s',$serverName,
            '-n','max_worker_processes','-v','16','-o','none') | Out-Null
        if ($serverName -eq $sourceName) {
            foreach ($pair in @(@('wal_level','logical'), @('max_replication_slots','10'), @('max_wal_senders','10'))) {
                Invoke-PocAz @('postgres','flexible-server','parameter','set','-g',$resourceGroup,'-s',$serverName,
                    '-n',$pair[0],'-v',$pair[1],'-o','none') | Out-Null
            }
        }
        Invoke-PocAz @('postgres','flexible-server','restart','-g',$resourceGroup,'-n',$serverName,'-o','none') | Out-Null
    }
    $source = @{ HostName = "$sourceName.postgres.database.azure.com"; User = $admin; Password = $adminPassword; ReplicationPassword = $replicationPassword }
    $target = @{ HostName = "$targetName.postgres.database.azure.com"; User = $admin; Password = $adminPassword; ReplicationPassword = $replicationPassword }
    $report.sourceEngine = Invoke-PocPg $source postgres 'SELECT version();'
    $report.targetEngine = Invoke-PocPg $target postgres 'SELECT version();'
    Assert-PocEqual 'wal_level' 'logical' (Invoke-PocPg $source postgres 'SHOW wal_level;')
    $report.sourceRole = (Invoke-PocPg $source postgres "SELECT jsonb_build_object('user',rolname,'superuser',rolsuper,'replication',rolreplication,'azure_pg_admin',pg_has_role(current_user,'azure_pg_admin','MEMBER'))::text FROM pg_roles WHERE rolname=current_user;") | ConvertFrom-Json
    # Disposable SYNTHETIC source only. Azure-services scope, NOT all Internet IPs.
    # It is removed after initial sync and replaced with observed subscriber IPv4s.
    Invoke-PocAz @('postgres','flexible-server','firewall-rule','create','-g',$resourceGroup,'-n',$sourceName,
        '--rule-name','poc-bootstrap-azure','--start-ip-address','0.0.0.0','--end-ip-address','0.0.0.0','-o','none') | Out-Null
    $report.bootstrapAzureRule = 'enabled-for-initial-connection-only'
    Save-RunReport
    $allowClient = {
        param([string]$Ip)
        $parsed = [Net.IPAddress]::Parse($Ip)
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $Ip -eq '0.0.0.0') { throw 'Refusing a broad or non-IPv4 firewall rule.' }
        Write-Host "Allowing specific subscriber egress IPv4 on publisher: $Ip"
        Invoke-PocAz @('postgres','flexible-server','firewall-rule','create','-g',$resourceGroup,'-n',$sourceName,
            '--rule-name',('subscriber-' + $Ip.Replace('.','-')),'--start-ip-address',$Ip,'--end-ip-address',$Ip,'-o','none') | Out-Null
        $report.firewall.Add(@{ server = $sourceName; purpose = 'subscriber-egress'; ip = $Ip })
        Save-RunReport
    }
    $restrictAfterSync = {
        $ips = Invoke-PocPg $source postgres "SELECT DISTINCT host(client_addr) FROM pg_stat_replication WHERE usename='poc_repl' AND client_addr IS NOT NULL;"
        if (-not $ips) { throw 'Could not observe subscriber IPv4; refusing to proceed with broad Azure-services rule.' }
        foreach ($ip in ($ips -split '\r?\n')) { & $allowClient $ip }
        if ($report.bootstrapAzureRule -ne 'removed-before-DML') {
            Invoke-PocAz @('postgres','flexible-server','firewall-rule','delete','-g',$resourceGroup,'-n',$sourceName,
                '--rule-name','poc-bootstrap-azure','--yes','-o','none') | Out-Null
            $report.bootstrapAzureRule = 'removed-before-DML'
        }
        $rules = Invoke-PocAz @('postgres','flexible-server','firewall-rule','list','-g',$resourceGroup,'-n',$sourceName,'-o','json') | ConvertFrom-Json
        foreach ($rule in $rules) {
            if ($rule.startIpAddress -ne $rule.endIpAddress -or $rule.startIpAddress -eq '0.0.0.0') {
                throw 'Unexpected broad publisher firewall rule remains.'
            }
        }
        $report.finalPublisherFirewall = @($rules | Select-Object name,startIpAddress,endIpAddress)
        Save-RunReport
        Write-Host 'Bootstrap rule removed; DML tests use specific-IP firewall rules only.'
    }
    & "$PSScriptRoot/Test-SchemaReplication.ps1" -Source $source -Target $target -OutputDirectory $OutputDirectory -AllowPublisherClient $allowClient -OnInitialSync $restrictAfterSync
    $report.status = 'passed'
} catch {
    $runError = Protect-PocText $_.Exception.Message $redactionSecrets
    $report.status = 'failed'
    $report.error = $runError
} finally {
    if ($createdGroup) {
        try {
            $exists = Invoke-PocAz @('group','exists','--name',$resourceGroup,'-o','tsv')
            if ($exists -eq 'true') {
                $group = Invoke-PocAz @('group','show','--name',$resourceGroup,'-o','json') | ConvertFrom-Json
                if ($group.tags.runId -ne $runId -or $group.tags.purpose -ne 'schema-replication-poc') {
                    throw 'Cleanup tag guard failed; resource group was NOT deleted.'
                }
                Write-Host "Deleting only disposable resource group $resourceGroup"
                Invoke-PocAz @('group','delete','--name',$resourceGroup,'--yes','-o','none') | Out-Null
            }
            Assert-PocEqual 'resource group deletion' 'false' (Invoke-PocAz @('group','exists','--name',$resourceGroup,'-o','tsv'))
            $report.cleanup = 'deleted-and-verified'
        } catch {
            $cleanupError = Protect-PocText $_.Exception.Message $redactionSecrets
            $report.cleanup = 'failed'
            $report.cleanupError = $cleanupError
        }
    }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-RunReport
    $adminPassword = $null; $replicationPassword = $null; $redactionSecrets = @()
}
if ($runError) { throw $runError }
if ($cleanupError) { throw $cleanupError }
Write-Host "Verification complete; resources removed. Evidence: $OutputDirectory"