#Requires -Version 7.2
<#
Run only on the disposable servers created by Invoke-AzureSchemaPoc.ps1.
Creates new databases; never reuses or drops pre-existing databases.
Passwords are in-memory inputs and are not included in reports.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable]$Source,
    [Parameter(Mandatory)][hashtable]$Target,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][scriptblock]$AllowPublisherClient,
    [Parameter(Mandatory)][scriptblock]$OnInitialSync,
    [int]$SyncTimeoutSeconds = 360
)
. "$PSScriptRoot/Common.ps1"
$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
$schemas = @('sales', 'hr')
$tables = @('sales.orders', 'sales.events', 'hr.people')
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

function Add-Check([string]$Name, [object]$Evidence) {
    $script:checks.Add([ordered]@{ name = $Name; status = 'passed'; evidence = $Evidence })
    Write-Host "PASS [$script:mode] $Name"
}

function Wait-ForReplica([string[]]$Relations) {
    foreach ($relation in $Relations) {
        $parts = $relation.Split('.')
        $sql = Get-PocDigestSql $parts[0] $parts[1]
        $expected = Invoke-PocPg $Source $script:database $sql
        $deadline = [DateTime]::UtcNow.AddSeconds($SyncTimeoutSeconds)
        do {
            $actual = Invoke-PocPg $Target $script:database $sql
            if ($actual -ceq $expected) { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-PocEqual $relation $expected $actual
        Add-Check "rows-and-digest:${relation}:$($script:phase)" ($actual | ConvertFrom-Json)
    }
}

function Assert-Excluded {
    $absent = Invoke-PocPg $Target $script:database "SELECT NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='internal');"
    Assert-PocEqual 'excluded schema absent on target' 't' $absent
    $notPublished = Invoke-PocPg $Source $script:database "SELECT count(*) FROM pg_publication_tables WHERE pubname='poc_pub' AND schemaname='internal';"
    Assert-PocEqual 'excluded schema absent from publication' '0' $notPublished
    Add-Check "excluded-schema:$script:phase" @{ targetSchemaAbsent = $true; publishedTables = 0 }
}

try {
    $replSecret = ConvertTo-PocLiteral $Source.ReplicationPassword
    Invoke-PocPg $Source postgres "CREATE ROLE poc_repl LOGIN REPLICATION PASSWORD $replSecret;" | Out-Null
    foreach ($script:mode in @('schema', 'tables')) {
        $script:database = "schema_poc_$script:mode"
        $script:checks = [Collections.Generic.List[object]]::new()
        $entry = [ordered]@{ mode = $script:mode; database = $script:database; status = 'running'; checks = $script:checks }
        $results.Add($entry)
        try {
            foreach ($server in @($Source, $Target)) {
                Invoke-PocPg $server postgres "CREATE DATABASE $script:database;" | Out-Null
            }
            Invoke-PocPg $Source $script:database (Get-Content "$PSScriptRoot/fixture.sql" -Raw) | Out-Null
            $sourceInventory = Invoke-PocPg $Source $script:database "SELECT string_agg(schemaname||'.'||tablename,',' ORDER BY schemaname,tablename) FROM pg_tables WHERE schemaname IN ('sales','hr','internal');"
            Assert-PocEqual 'source fixture' 'hr.people,internal.audit,sales.events,sales.orders' $sourceInventory
            Add-Check 'source-all-fixture-schemas' $sourceInventory
            Invoke-PocPg $Source $script:database @"
GRANT CONNECT ON DATABASE $script:database TO poc_repl;
GRANT USAGE ON SCHEMA sales, hr TO poc_repl;
GRANT SELECT ON ALL TABLES IN SCHEMA sales, hr TO poc_repl;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales, hr GRANT SELECT ON TABLES TO poc_repl;
"@ | Out-Null
            $dump = Join-Path $OutputDirectory "$script:mode-selected-schema.sql"
            Export-PocSchema $Source $script:database $schemas $dump
            Invoke-PocPg $Target $script:database (Get-Content $dump -Raw) | Out-Null
            $targetInventory = Invoke-PocPg $Target $script:database "SELECT string_agg(schemaname||'.'||tablename,',' ORDER BY schemaname,tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');"
            Assert-PocEqual 'target selected tables only' 'hr.people,sales.events,sales.orders' $targetInventory
            Add-Check 'target-selected-schema-dump' $targetInventory
            $sequenceBaseline = Invoke-PocPg $Target $script:database 'SELECT last_value::text||''|''||is_called::text FROM sales.orders_id_seq;'
            if ($script:mode -eq 'schema') {
                try {
                    Invoke-PocPg $Source $script:database 'CREATE PUBLICATION poc_pub FOR TABLES IN SCHEMA sales, hr;' | Out-Null
                } catch {
                    if ($_.Exception.Message -notmatch '(?i)superuser|permission denied|not permitted') { throw }
                    $entry.status = 'unsupported-permission'
                    $entry.reason = $_.Exception.Message
                    Write-Host 'Schema-level publication rejected by Azure; explicit-table mode will still be tested.'
                    continue
                }
            } else {
                # Resolve the selected schemas to a quoted, explicit table list; no FOR ALL TABLES.
                $list = Invoke-PocPg $Source $script:database @"
SELECT string_agg(format('%I.%I',n.nspname,c.relname),', ' ORDER BY n.nspname,c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('sales','hr') AND c.relkind='r' AND c.relpersistence='p';
"@
                if (-not $list) { throw 'Selected schemas contain no publishable tables.' }
                Invoke-PocPg $Source $script:database "CREATE PUBLICATION poc_pub FOR TABLE $list;" | Out-Null
            }
            Add-Check 'create-publication' $script:mode
            $pubTables = Invoke-PocPg $Source $script:database "SELECT string_agg(schemaname||'.'||tablename,',' ORDER BY schemaname,tablename) FROM pg_publication_tables WHERE pubname='poc_pub';"
            Assert-PocEqual 'published tables' $targetInventory $pubTables
            Add-Check 'publication-exact-table-set' $pubTables

            $conn = "host=$($Source.HostName) port=5432 dbname=$script:database user=poc_repl password=$($Source.ReplicationPassword) sslmode=require connect_timeout=15"
            $createSubscription = 'CREATE SUBSCRIPTION poc_sub CONNECTION ' + (ConvertTo-PocLiteral $conn) + ' PUBLICATION poc_pub WITH (copy_data=true);'
            $connected = $false
            for ($attempt = 0; $attempt -lt 4; $attempt++) {
                try {
                    Invoke-PocPg $Target $script:database $createSubscription | Out-Null
                    $connected = $true
                    break
                } catch {
                    # PostgreSQL tells us the actual subscriber egress IP. Allow that exact IPv4 only.
                    $message = $_.Exception.Message
                    if ($message -match '(?i)(?:no pg_hba.conf entry|pg_hba.conf rejects connection) for host "(?<ip>\d{1,3}(?:\.\d{1,3}){3})"') {
                        & $AllowPublisherClient $Matches.ip
                    } elseif ($message -match '(?i)statement timeout|connection.*timed out|timeout expired' -and $attempt -lt 3) {
                        # Firewall propagation may take five minutes. Retry only a provably
                        # absent subscription/slot; never duplicate or reset replication state.
                        $subCount = Invoke-PocPg $Target $script:database "SELECT count(*) FROM pg_subscription WHERE subname='poc_sub';"
                        $slotCount = Invoke-PocPg $Source $script:database "SELECT count(*) FROM pg_replication_slots WHERE slot_name='poc_sub';"
                        if ($subCount -ne '0' -or $slotCount -ne '0') { throw 'Timed-out creation left replication state; refusing blind retry.' }
                        Write-Host "Retrying initial connection after timeout; subscription and slot are both absent (attempt $($attempt+2)/4)."
                    } else { throw }
                }
            }
            if (-not $connected) { throw 'Could not connect subscriber after specific-IP firewall retries.' }
            $script:phase = 'initial-copy'
            Wait-ForReplica $tables
            $deadline = [DateTime]::UtcNow.AddSeconds($SyncTimeoutSeconds)
            do {
                $ready = Invoke-PocPg $Target $script:database "SELECT count(*)=3 AND bool_and(srsubstate='r') FROM pg_subscription_rel;"
                if ($ready -eq 't') { break }
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-PocEqual 'all initial table sync states ready' 't' $ready
            Add-Check 'initial-sync-ready' $true
            Assert-Excluded
            & $OnInitialSync
            Add-Check 'network-restricted-before-DML' $true
            # Force a fresh network connection; do not rely on an already allowed socket.
            Invoke-PocPg $Target $script:database 'ALTER SUBSCRIPTION poc_sub DISABLE;' | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds($SyncTimeoutSeconds)
            do {
                $active = Invoke-PocPg $Source $script:database "SELECT active FROM pg_replication_slots WHERE slot_name='poc_sub';"
                if ($active -eq 'f') { break }
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-PocEqual 'subscriber disconnected before network recheck' 'f' $active
            Invoke-PocPg $Target $script:database 'ALTER SUBSCRIPTION poc_sub ENABLE;' | Out-Null

            $operations = [ordered]@{
                insert = "INSERT INTO sales.orders(description,amount) VALUES ('inserted',999); INSERT INTO hr.people VALUES (2,'inserted'); INSERT INTO internal.audit VALUES (2,'excluded-insert');"
                update = "UPDATE sales.orders SET amount=12345,description='updated' WHERE id=1; UPDATE hr.people SET description='updated' WHERE id=1; UPDATE internal.audit SET description='excluded-update' WHERE id=1;"
                delete = 'DELETE FROM sales.orders WHERE id=2; DELETE FROM hr.people WHERE id=2; DELETE FROM internal.audit WHERE id=2;'
                transaction = "BEGIN; INSERT INTO sales.orders(description,amount) VALUES ('transaction',777); INSERT INTO sales.events VALUES(2,'transaction'); INSERT INTO hr.people VALUES(3,'transaction'); COMMIT;"
                rollback = "BEGIN; INSERT INTO sales.events VALUES(999,'must-rollback'); ROLLBACK;"
                truncate = 'TRUNCATE sales.events;'
            }
            foreach ($operation in $operations.Keys) {
                $script:phase = $operation
                Invoke-PocPg $Source $script:database $operations[$operation] | Out-Null
                Wait-ForReplica $tables
                Assert-Excluded
            }
            $audit = Invoke-PocPg $Source $script:database "SELECT id||':'||description FROM internal.audit ORDER BY id;"
            Assert-PocEqual 'excluded DML really ran on source' '1:excluded-update' $audit
            Add-Check 'source-excluded-DML-executed' $audit

            # No DDL replication: source creation alone must not create the target table.
            $newTable = 'CREATE TABLE sales.new_orders(id bigint PRIMARY KEY, description text NOT NULL);'
            Invoke-PocPg $Source $script:database "$newTable INSERT INTO sales.new_orders VALUES(1,'before-refresh');" | Out-Null
            Assert-PocEqual 'DDL not replicated' 't' (Invoke-PocPg $Target $script:database "SELECT to_regclass('sales.new_orders') IS NULL;")
            Add-Check 'DDL-not-automatically-replicated' $true
            $automatic = Invoke-PocPg $Source $script:database "SELECT count(*) FROM pg_publication_tables WHERE pubname='poc_pub' AND schemaname='sales' AND tablename='new_orders';"
            Assert-PocEqual 'new table publisher membership' $(if ($script:mode -eq 'schema') { '1' } else { '0' }) $automatic
            Add-Check 'new-table-auto-publication-membership' $automatic
            Invoke-PocPg $Target $script:database $newTable | Out-Null
            Assert-PocEqual 'new target table empty before refresh' '0' (Invoke-PocPg $Target $script:database 'SELECT count(*) FROM sales.new_orders;')
            Assert-PocEqual 'new target table not subscribed before refresh' '0' (Invoke-PocPg $Target $script:database "SELECT count(*) FROM pg_subscription_rel WHERE srrelid='sales.new_orders'::regclass;")
            Add-Check 'new-table-not-subscribed-before-refresh' $true
            if ($script:mode -eq 'tables') {
                Invoke-PocPg $Source $script:database 'ALTER PUBLICATION poc_pub ADD TABLE sales.new_orders;' | Out-Null
            }
            Invoke-PocPg $Target $script:database 'ALTER SUBSCRIPTION poc_sub REFRESH PUBLICATION WITH(copy_data=true);' | Out-Null
            $script:phase = 'new-table-initial-copy'
            Wait-ForReplica @('sales.new_orders')
            Invoke-PocPg $Source $script:database "INSERT INTO sales.new_orders VALUES(2,'after-refresh');" | Out-Null
            $script:phase = 'new-table-DML'
            Wait-ForReplica @('sales.new_orders')

            # Quiescent fixture: no source writes from this point through cutover.
            $script:phase = 'cutover'
            Wait-ForReplica ($tables + @('sales.new_orders'))
            $slot = Invoke-PocPg $Source $script:database "SELECT jsonb_build_object('active',active,'plugin',plugin,'retained_wal_bytes',pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn))::text FROM pg_replication_slots WHERE slot_name='poc_sub';"
            Add-Check 'slot-observed-before-cutover' ($slot | ConvertFrom-Json)
            $sequence = Invoke-PocPg $Source $script:database 'SELECT last_value FROM sales.orders_id_seq;'
            $targetSeq = Invoke-PocPg $Target $script:database 'SELECT last_value FROM sales.orders_id_seq;'
            $sequenceFinal = Invoke-PocPg $Target $script:database 'SELECT last_value::text||''|''||is_called::text FROM sales.orders_id_seq;'
            Assert-PocEqual 'target sequence remains at dump baseline' $sequenceBaseline $sequenceFinal
            if ([long]$sequence -le [long]$targetSeq) { throw 'Fixture failed to demonstrate unsynchronized sequence state.' }
            Add-Check 'sequence-state-not-replicated' @{ source = $sequence; target = $targetSeq }
            Invoke-PocPg $Target $script:database 'ALTER SUBSCRIPTION poc_sub DISABLE; DROP SUBSCRIPTION poc_sub;' | Out-Null
            Assert-PocEqual 'slot removed after drop subscription' '0' (Invoke-PocPg $Source $script:database "SELECT count(*) FROM pg_replication_slots WHERE slot_name='poc_sub';")
            Add-Check 'subscription-and-slot-cleanup' $true
            $newId = Invoke-PocPg $Target $script:database "SELECT setval('sales.orders_id_seq',$sequence,true); INSERT INTO sales.orders(description,amount) VALUES('target-after-cutover',1) RETURNING id;"
            $actualId = ($newId -split '\r?\n')[-1]
            Assert-PocEqual 'target identity after sequence sync' ([string]([long]$sequence + 1)) $actualId
            Add-Check 'sequence-sync-and-target-write' $actualId
            Assert-PocEqual 'source unaffected by target write' '0' (Invoke-PocPg $Source $script:database "SELECT count(*) FROM sales.orders WHERE description='target-after-cutover';")
            $script:phase = 'final'
            Assert-Excluded
            Invoke-PocPg $Source $script:database 'DROP PUBLICATION poc_pub;' | Out-Null
            $entry.status = 'passed'
        } catch {
            $entry.status = 'failed'
            $entry.error = Protect-PocText $_.Exception.Message @($Source.Password, $Target.Password, $Source.ReplicationPassword)
            try {
                $entry.sourceDiagnostics = (Invoke-PocPg $Source postgres @"
SELECT jsonb_build_object(
 'replication_sessions',(SELECT COALESCE(jsonb_agg(jsonb_build_object('user',usename,'client',client_addr,'state',state,'wait_type',wait_event_type,'wait',wait_event)),'[]'::jsonb) FROM pg_stat_activity WHERE usename='poc_repl'),
 'slots',(SELECT COALESCE(jsonb_agg(jsonb_build_object('slot',slot_name,'active',active,'database',database)),'[]'::jsonb) FROM pg_replication_slots WHERE slot_name='poc_sub'))::text;
"@) | ConvertFrom-Json
            } catch { $entry.diagnosticsError = 'Source diagnostics unavailable.' }
            throw
        }
    }
    if (@($results | Where-Object status -eq 'passed').Count -eq 0) { throw 'No replication mode passed.' }
} finally {
    ConvertTo-Json -InputObject @($results.ToArray()) -Depth 12 | Set-Content (Join-Path $OutputDirectory 'verification.json') -Encoding utf8
}