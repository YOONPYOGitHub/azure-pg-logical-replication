#Requires -Version 5.1
<#
.SYNOPSIS
    Azure PostgreSQL Logical Replication Pre-Validation Script (PowerShell)
.DESCRIPTION
    Performs 24 pre-migration validation checks for Logical Replication (pgoutput + pub/sub).
    DB 배열을 지정하면 서버 레벨 검증은 1회, DB 레벨 검증은 DB별로 수행합니다.
    Requires psql and pg_dump in PATH.

    실행 순서:
      타겟 서버 생성 → 빈 DB 생성 → 스크립트 실행 → 스키마 마이그레이션 → 데이터 마이그레이션
.EXAMPLE
    .\pre_migration_validation.ps1
    .\pre_migration_validation.ps1 -SrcHost "pg-old.postgres.database.azure.com" -TgtHost "pg-new.postgres.database.azure.com"
    .\pre_migration_validation.ps1 -Databases "adventureworks","adventureworks2","mydb"
#>

[CmdletBinding()]
param(
    [string]$SrcHost     = "pg-old.postgres.database.azure.com",
    [string]$SrcUser     = "<adminuser>",
    [string]$SrcPass     = '<password>',

    [string]$TgtHost     = "pg-new.postgres.database.azure.com",
    [string]$TgtUser     = "<adminuser>",
    [string]$TgtPass     = '<password>',

    # 마이그레이션 대상 DB 목록 (소스/타겟 동일 이름)
    [string[]]$Databases = @("adventureworks", "adventureworks2")
)

$ErrorActionPreference = "Continue"

# ============================================================
# Server-level connection strings (postgres DB)
# ============================================================
$SrcSrvConn = "host=$SrcHost port=5432 dbname=postgres user=$SrcUser sslmode=require"
$TgtSrvConn = "host=$TgtHost port=5432 dbname=postgres user=$TgtUser sslmode=require"

# ============================================================
# Work directory
# ============================================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$WorkDir = Join-Path $PSScriptRoot "validation_$timestamp"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# ============================================================
# Counters
# ============================================================
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Pass  ([string]$Name) { Write-Host "$Name .......... " -NoNewline; Write-Host "Succeeded" -ForegroundColor Green;  $script:PassCount++ }
function Write-Fail  ([string]$Name) { Write-Host "$Name .......... " -NoNewline; Write-Host "Failed"    -ForegroundColor Red;    $script:FailCount++ }
function Write-Warn  ([string]$Name) { Write-Host "$Name .......... " -NoNewline; Write-Host "Warning"   -ForegroundColor Yellow; $script:WarnCount++ }

# ============================================================
# Helper: server-level queries (postgres DB)
# ============================================================
function Invoke-SrcSrv ([string]$Query) {
    $env:PGPASSWORD = $SrcPass
    $result = & psql $SrcSrvConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

function Invoke-TgtSrv ([string]$Query) {
    $env:PGPASSWORD = $TgtPass
    $result = & psql $TgtSrvConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

# ============================================================
# Helper: DB-level queries (uses $curSrcConn / $curTgtConn set in loop)
# ============================================================
function Invoke-Src ([string]$Query) {
    $env:PGPASSWORD = $SrcPass
    $result = & psql $script:curSrcConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

function Invoke-Tgt ([string]$Query) {
    $env:PGPASSWORD = $TgtPass
    $result = & psql $script:curTgtConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

# ============================================================
# Header
# ============================================================
Write-Host "============================================"
Write-Host "  Migration Pre-Validation"
Write-Host "  Source : $SrcHost"
Write-Host "  Target : $TgtHost"
Write-Host "  DBs    : $($Databases -join ', ')"
Write-Host "  Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================"
Write-Host ""

# ════════════════════════════════════════════════
#  Phase 1: Server-Level Validation (postgres DB, 1회 실행)
# ════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host "  Phase 1: Server-Level Validation"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Server Connection ──
try {
    $env:PGPASSWORD = $SrcPass
    & psql $SrcSrvConn -c "SELECT 1;" 2>$null | Out-Null
    $srcOk = $LASTEXITCODE -eq 0

    $env:PGPASSWORD = $TgtPass
    & psql $TgtSrvConn -c "SELECT 1;" 2>$null | Out-Null
    $tgtOk = $LASTEXITCODE -eq 0
    $env:PGPASSWORD = $null

    if ($srcOk -and $tgtOk) {
        Write-Pass "ServerConnectionValidation"
    } else {
        Write-Fail "ServerConnectionValidation"
        Write-Host "  -> Cannot connect to source or target server. Exiting."
        exit 1
    }
} catch {
    Write-Fail "ServerConnectionValidation"
    Write-Host "  -> Cannot connect to source or target server. Exiting."
    exit 1
}

# ── 2. VersionCompatibilityValidation ──
$srcVer       = (Invoke-SrcSrv "SHOW server_version_num;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
$tgtVer       = (Invoke-TgtSrv "SHOW server_version_num;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
$srcVerPretty = (Invoke-SrcSrv "SHOW server_version;")     | ForEach-Object { $_.Trim() } | Select-Object -First 1
$tgtVerPretty = (Invoke-TgtSrv "SHOW server_version;")     | ForEach-Object { $_.Trim() } | Select-Object -First 1

if ([int]($tgtVer ?? 0) -ge [int]($srcVer ?? 999999)) {
    Write-Pass "VersionCompatibilityValidation"
    Write-Host "  -> source: $($srcVerPretty ?? 'unknown'), target: $($tgtVerPretty ?? 'unknown')"
} else {
    Write-Warn "VersionCompatibilityValidation"
    Write-Host "  -> source: $($srcVerPretty ?? 'unknown'), target: $($tgtVerPretty ?? 'unknown')"
    Write-Host "  -> target version is lower than source"
}

# ── 3. WalLevelValidation ──
$wl = (Invoke-SrcSrv "SHOW wal_level;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
if ($wl -eq "logical") {
    Write-Pass "WalLevelValidation"
} else {
    Write-Fail "WalLevelValidation"
    Write-Host "  -> source wal_level: $($wl ?? 'unknown') (expected: logical)"
}

# ── 4. MaxReplicationSlotsValidation ──
$mrs = (Invoke-SrcSrv "SHOW max_replication_slots;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
$dbCount = $Databases.Count
$slotsNeeded = $dbCount  # DB당 최소 1 slot
if ([int]($mrs ?? 0) -ge $slotsNeeded) {
    Write-Pass "MaxReplicationSlotsValidation"
    Write-Host "  -> max_replication_slots: $($mrs ?? 0) (need >= $slotsNeeded for $dbCount DBs)"
} else {
    Write-Fail "MaxReplicationSlotsValidation"
    Write-Host "  -> max_replication_slots: $($mrs ?? 0) (need >= $slotsNeeded for $dbCount DBs)"
}

# ── 5. MaxWalSendersValidation ──
$mws = (Invoke-SrcSrv "SHOW max_wal_senders;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
if ([int]($mws ?? 0) -ge $slotsNeeded) {
    Write-Pass "MaxWalSendersValidation"
    Write-Host "  -> max_wal_senders: $($mws ?? 0) (need >= $slotsNeeded for $dbCount DBs)"
} else {
    Write-Fail "MaxWalSendersValidation"
    Write-Host "  -> max_wal_senders: $($mws ?? 0) (need >= $slotsNeeded for $dbCount DBs)"
}

# ── 18. UserRolesValidation ──
$srcRoles = (Invoke-SrcSrv @"
SELECT rolname FROM pg_roles
WHERE rolname NOT LIKE 'pg_%'
  AND rolname NOT IN ('azure_superuser','azure_pg_admin','replication','azuresu')
ORDER BY 1;
"@) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

$srcRoles | Set-Content (Join-Path $WorkDir "src_roles.txt")

$tgtRoles = (Invoke-TgtSrv "SELECT rolname FROM pg_roles ORDER BY 1;") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$tgtRoles | Set-Content (Join-Path $WorkDir "tgt_roles.txt")

$missingRoles = $srcRoles | Where-Object { $_ -notin $tgtRoles }

if (-not $missingRoles) {
    Write-Pass "UserRolesValidation"
} else {
    Write-Fail "UserRolesValidation"
    $missingRoles | Set-Content (Join-Path $WorkDir "missing_roles.txt")
    Write-Host "  -> roles missing on target:"
    $missingRoles | ForEach-Object { Write-Host "     $_" }
}

# ── 19. TablespaceValidation ──
$customTs = (Invoke-SrcSrv @"
SELECT spcname FROM pg_tablespace
WHERE spcname NOT IN ('pg_default','pg_global')
ORDER BY 1;
"@) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if (-not $customTs) {
    Write-Pass "TablespaceValidation"
} else {
    Write-Warn "TablespaceValidation"
    Write-Host "  -> custom tablespaces: $($customTs -join ', ')"
}

# ── 20. ReplicationRoleValidation ──
$srcRepl = (Invoke-SrcSrv "SELECT rolreplication FROM pg_roles WHERE rolname = current_user;") | ForEach-Object { $_.Trim() } | Select-Object -First 1

if ($srcRepl -eq "t") {
    Write-Pass "ReplicationRoleValidation"
} else {
    Write-Fail "ReplicationRoleValidation"
    Write-Host "  -> source user '$SrcUser' does not have REPLICATION attribute"
    Write-Host "  -> fix: ALTER ROLE $SrcUser WITH REPLICATION;"
}

# ── 21. MaxWorkerProcessesValidation ──
$srcMwp = (Invoke-SrcSrv "SHOW max_worker_processes;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
$tgtMwp = (Invoke-TgtSrv "SHOW max_worker_processes;") | ForEach-Object { $_.Trim() } | Select-Object -First 1

$mwpOk = ([int]($srcMwp ?? 0) -ge 16) -and ([int]($tgtMwp ?? 0) -ge 16)

if ($mwpOk) {
    Write-Pass "MaxWorkerProcessesValidation"
    Write-Host "  -> source: $($srcMwp ?? 'unknown'), target: $($tgtMwp ?? 'unknown')"
} else {
    Write-Warn "MaxWorkerProcessesValidation"
    Write-Host "  -> source: $($srcMwp ?? 'unknown'), target: $($tgtMwp ?? 'unknown') (recommended >= 16)"
}

Write-Host ""

# ════════════════════════════════════════════════
#  Phase 2: DB-Level Validation (DB별 루프)
# ════════════════════════════════════════════════
foreach ($dbName in $Databases) {
    $dbDir = Join-Path $WorkDir $dbName
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null

    $script:curSrcConn = "host=$SrcHost port=5432 dbname=$dbName user=$SrcUser sslmode=require"
    $script:curTgtConn = "host=$TgtHost port=5432 dbname=$dbName user=$TgtUser sslmode=require"

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "  Phase 2: DB-Level Validation [$dbName]"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── 1. ConnectionValidation ──
    try {
        $env:PGPASSWORD = $SrcPass
        & psql $script:curSrcConn -c "SELECT 1;" 2>$null | Out-Null
        $srcOk = $LASTEXITCODE -eq 0

        $env:PGPASSWORD = $TgtPass
        & psql $script:curTgtConn -c "SELECT 1;" 2>$null | Out-Null
        $tgtOk = $LASTEXITCODE -eq 0
        $env:PGPASSWORD = $null

        if ($srcOk -and $tgtOk) {
            Write-Pass "[$dbName] ConnectionValidation"
        } else {
            Write-Fail "[$dbName] ConnectionValidation"
            Write-Host "  -> Cannot connect to $dbName on source or target. Skipping this DB."
            continue
        }
    } catch {
        Write-Fail "[$dbName] ConnectionValidation"
        Write-Host "  -> Cannot connect to $dbName on source or target. Skipping this DB."
        continue
    }

    # ── 6. MissingPrimaryKeysValidation ──
    $pkQuery = @"
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.oid AND i.indisprimary
  )
  AND c.relreplident NOT IN ('f','i');
"@

    $pkCnt = (Invoke-Src $pkQuery) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if (($pkCnt ?? "0") -eq "0") {
        Write-Pass "[$dbName] MissingPrimaryKeysValidation"
    } else {
        Write-Fail "[$dbName] MissingPrimaryKeysValidation"
        Write-Host "  -> tables without PK and without REPLICA IDENTITY FULL/INDEX: $pkCnt"
        Write-Host "  -> fix: add PK or set REPLICA IDENTITY FULL/USING INDEX"

        $pkDetailQuery = @"
SELECT n.nspname || '.' || c.relname || ' (replica_identity=' || c.relreplident || ')'
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.oid AND i.indisprimary
  )
  AND c.relreplident NOT IN ('f','i')
ORDER BY 1;
"@
        Invoke-Src $pkDetailQuery | Set-Content (Join-Path $dbDir "missing_primary_keys.txt")
        Write-Host "  -> detail: $dbDir\missing_primary_keys.txt"
    }

    # ── 7. ExtensionsValidation ──
    $srcExt = (Invoke-Src "SELECT extname FROM pg_extension ORDER BY 1;") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $tgtAvailExt = (Invoke-Tgt "SELECT name FROM pg_available_extensions ORDER BY 1;") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $srcExt      | Set-Content (Join-Path $dbDir "src_extensions.txt")
    $tgtAvailExt | Set-Content (Join-Path $dbDir "tgt_available_extensions.txt")

    $missingExt = $srcExt | Where-Object { $_ -notin $tgtAvailExt }

    if (-not $missingExt) {
        Write-Pass "[$dbName] ExtensionsValidation"
    } else {
        Write-Fail "[$dbName] ExtensionsValidation"
        $missingExt | Set-Content (Join-Path $dbDir "missing_extensions.txt")
        Write-Host "  -> extensions unavailable on target:"
        $missingExt | ForEach-Object { Write-Host "     $_" }
    }

    # ── 8. LanguageValidation ──
    $srcLang = (Invoke-Src "SELECT lanname FROM pg_language ORDER BY 1;") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $tgtLang = (Invoke-Tgt "SELECT lanname FROM pg_language ORDER BY 1;") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $srcLang | Set-Content (Join-Path $dbDir "src_languages.txt")
    $tgtLang | Set-Content (Join-Path $dbDir "tgt_languages.txt")

    $langDiff = Compare-Object -ReferenceObject ($srcLang ?? @()) -DifferenceObject ($tgtLang ?? @()) -PassThru
    if (-not $langDiff) {
        Write-Pass "[$dbName] LanguageValidation"
    } else {
        Write-Fail "[$dbName] LanguageValidation"
        $langDiff | Set-Content (Join-Path $dbDir "languages_diff.txt")
        Write-Host "  -> detail: $dbDir\languages_diff.txt"
    }

    # ── 9. LargeObjectValidation ──
    $lobCnt = (Invoke-Src "SELECT count(*) FROM pg_largeobject_metadata;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
    if (($lobCnt ?? "0") -eq "0") {
        Write-Pass "[$dbName] LargeObjectValidation"
    } else {
        Write-Warn "[$dbName] LargeObjectValidation"
        Write-Host "  -> large objects found: $lobCnt"
        Write-Host "  -> logical replication does NOT replicate pg_largeobject"
    }

    # ── 10. EncodingValidation ──
    $encSrc = (Invoke-Src "SHOW server_encoding;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
    $encTgt = (Invoke-Tgt "SHOW server_encoding;") | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if ($encSrc -and ($encSrc -eq $encTgt)) {
        Write-Pass "[$dbName] EncodingValidation"
    } else {
        Write-Fail "[$dbName] EncodingValidation"
        Write-Host "  -> source: $($encSrc ?? 'unknown'), target: $($encTgt ?? 'unknown')"
    }

    # ── 11. CollationsValidation ──
    $collQuery = @"
SELECT collname, collprovider, collcollate, collctype
FROM pg_collation
WHERE collnamespace != (SELECT oid FROM pg_namespace WHERE nspname = 'pg_catalog')
ORDER BY 1;
"@

    $srcColl = (Invoke-Src $collQuery) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $tgtColl = (Invoke-Tgt $collQuery) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $srcColl | Set-Content (Join-Path $dbDir "src_collations.txt")
    $tgtColl | Set-Content (Join-Path $dbDir "tgt_collations.txt")

    $collDiff = Compare-Object -ReferenceObject ($srcColl ?? @()) -DifferenceObject ($tgtColl ?? @()) -PassThru
    if (-not $collDiff) {
        Write-Pass "[$dbName] CollationsValidation"
    } else {
        Write-Fail "[$dbName] CollationsValidation"
        $collDiff | Set-Content (Join-Path $dbDir "collations_diff.txt")
        Write-Host "  -> detail: $dbDir\collations_diff.txt"
    }

    # ── 12. ReplicaIdentityValidation ──
    $riQuery = @"
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND c.relreplident = 'n';
"@

    $riCnt = (Invoke-Src $riQuery) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if (($riCnt ?? "0") -eq "0") {
        Write-Pass "[$dbName] ReplicaIdentityValidation"
    } else {
        Write-Fail "[$dbName] ReplicaIdentityValidation"
        Write-Host "  -> tables with REPLICA IDENTITY NOTHING: $riCnt"

        $riDetailQuery = @"
SELECT n.nspname || '.' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND c.relreplident = 'n'
ORDER BY 1;
"@
        Invoke-Src $riDetailQuery | Set-Content (Join-Path $dbDir "replica_identity_nothing.txt")
        Write-Host "  -> detail: $dbDir\replica_identity_nothing.txt"
    }

    # ── 13. SchemaValidation (pg_dump --schema-only) ──
    $schemaDumpFile = Join-Path $dbDir "source_schema.sql"
    $env:PGPASSWORD = $SrcPass
    & pg_dump $script:curSrcConn --schema-only --no-owner --no-privileges -f $schemaDumpFile 2>$null | Out-Null
    $env:PGPASSWORD = $null

    if ($LASTEXITCODE -eq 0 -and (Test-Path $schemaDumpFile)) {
        Write-Pass "[$dbName] SchemaValidation"
    } else {
        Write-Fail "[$dbName] SchemaValidation"
    }

    # ── 14. CreateSchemaValidation ──
    $tmpSchema = "validation_tmp_$(Get-Date -Format 'yyyyMMddHHmmss')"

    $env:PGPASSWORD = $TgtPass
    & psql $script:curTgtConn -c "CREATE SCHEMA IF NOT EXISTS $tmpSchema;" 2>$null | Out-Null
    $createOk = $LASTEXITCODE -eq 0

    if ($createOk) {
        & psql $script:curTgtConn -c "DROP SCHEMA IF EXISTS $tmpSchema;" 2>$null | Out-Null
        Write-Pass "[$dbName] CreateSchemaValidation"
    } else {
        Write-Fail "[$dbName] CreateSchemaValidation"
    }
    $env:PGPASSWORD = $null

    # ── 15. SequenceSyncWarning ──
    $seqCnt = (Invoke-Src @"
SELECT count(*)
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog','information_schema');
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if (($seqCnt ?? "0") -eq "0") {
        Write-Pass "[$dbName] SequenceSyncWarning"
    } else {
        Write-Warn "[$dbName] SequenceSyncWarning"
        Write-Host "  -> sequences found: $seqCnt"
        Write-Host "  -> logical replication does NOT sync sequence values"

        (Invoke-Src @"
SELECT schemaname || '.' || sequencename || ' (last_value=' || COALESCE(last_value::text,'NULL') || ')'
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY 1;
"@) | Set-Content (Join-Path $dbDir "sequences.txt")
        Write-Host "  -> detail: $dbDir\sequences.txt"
    }

    # ── 16. CreatePublicationValidation ──
    Invoke-Src "CREATE PUBLICATION validation_pub_temp FOR ALL TABLES;" 2>$null | Out-Null
    $pubCreateOk = $LASTEXITCODE -eq 0

    if ($pubCreateOk) {
        Invoke-Src "DROP PUBLICATION validation_pub_temp;" 2>$null | Out-Null
        Write-Pass "[$dbName] CreatePublicationValidation"
    } else {
        Invoke-Src "DROP PUBLICATION IF EXISTS validation_pub_temp;" 2>$null | Out-Null
        Write-Fail "[$dbName] CreatePublicationValidation"
    }

    # ── 17. RuleEngineValidation ──
    $ruleCnt = (Invoke-Src "SELECT count(*) FROM pg_rules WHERE schemaname NOT IN ('pg_catalog','information_schema');") | ForEach-Object { $_.Trim() } | Select-Object -First 1
    $trgCnt  = (Invoke-Src @"
SELECT count(*)
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname NOT IN ('pg_catalog','information_schema');
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    $tgtTrgCnt = (Invoke-Tgt @"
SELECT count(*)
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname NOT IN ('pg_catalog','information_schema');
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if (($ruleCnt ?? "0") -eq "0" -and ($trgCnt ?? "0") -eq "0" -and ($tgtTrgCnt ?? "0") -eq "0") {
        Write-Pass "[$dbName] RuleEngineValidation"
    } else {
        Write-Warn "[$dbName] RuleEngineValidation"
        Write-Host "  -> source rules: $($ruleCnt ?? 0), source triggers: $($trgCnt ?? 0)"
        Write-Host "  -> target triggers: $($tgtTrgCnt ?? 0)"
        if (($tgtTrgCnt ?? "0") -ne "0") {
            Write-Host "  -> WARNING: target triggers may fire on replicated rows (double execution)"
            Write-Host "  -> consider: ALTER TABLE ... DISABLE TRIGGER ... on target during replication"
        }

        (Invoke-Src @"
SELECT schemaname, tablename, rulename, definition
FROM pg_rules
WHERE schemaname NOT IN ('pg_catalog','information_schema')
ORDER BY 1,2,3;
"@) | Set-Content (Join-Path $dbDir "rules_detail.txt")

        (Invoke-Src @"
SELECT n.nspname, c.relname, t.tgname, t.tgenabled
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY 1,2,3;
"@) | Set-Content (Join-Path $dbDir "triggers_detail.txt")

        if (($tgtTrgCnt ?? "0") -ne "0") {
            (Invoke-Tgt @"
SELECT n.nspname, c.relname, t.tgname, t.tgenabled
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY 1,2,3;
"@) | Set-Content (Join-Path $dbDir "target_triggers_detail.txt")
        }
    }

    # ── 22. CreateSubscriptionValidation ──
    $tgtSubPerm = (Invoke-Tgt @"
SELECT CASE
  WHEN rolsuper THEN 'true'
  WHEN pg_has_role(current_user, 'azure_pg_admin', 'MEMBER') THEN 'true'
  ELSE 'false'
END
FROM pg_roles WHERE rolname = current_user;
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if ($tgtSubPerm -eq "true") {
        Write-Pass "[$dbName] CreateSubscriptionValidation"
    } else {
        Write-Fail "[$dbName] CreateSubscriptionValidation"
        Write-Host "  -> target user '$TgtUser' cannot create subscriptions"
        Write-Host "  -> fix: GRANT azure_pg_admin TO $TgtUser;"
    }

    # ── 23. TargetSchemaReadyValidation ──
    $srcTblCnt = (Invoke-Src @"
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema');
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    $tgtTblCnt = (Invoke-Tgt @"
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema');
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if ([int]($tgtTblCnt ?? 0) -ge [int]($srcTblCnt ?? 0) -and [int]($srcTblCnt ?? 0) -gt 0) {
        Write-Pass "[$dbName] TargetSchemaReadyValidation"
        Write-Host "  -> source tables: $srcTblCnt, target tables: $tgtTblCnt"
    } else {
        Write-Warn "[$dbName] TargetSchemaReadyValidation"
        Write-Host "  -> source tables: $($srcTblCnt ?? 0), target tables: $($tgtTblCnt ?? 0)"
        if (($tgtTblCnt ?? "0") -eq "0") {
            Write-Host "  -> target has no user tables yet"
        } else {
            Write-Host "  -> target has fewer tables than source"
        }
        Write-Host "  -> run: pg_dump --schema-only | psql target (before data migration step)"
    }

    # ── 24. ExistingReplicationResourcesValidation ──
    $existPub  = (Invoke-Src "SELECT count(*) FROM pg_publication;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
    $existSlot = (Invoke-Src @"
SELECT count(*) FROM pg_replication_slots
WHERE slot_type = 'logical' AND database = current_database();
"@) | ForEach-Object { $_.Trim() } | Select-Object -First 1
    $existSub  = (Invoke-Tgt "SELECT count(*) FROM pg_subscription;") | ForEach-Object { $_.Trim() } | Select-Object -First 1

    if (($existPub ?? "0") -eq "0" -and ($existSlot ?? "0") -eq "0" -and ($existSub ?? "0") -eq "0") {
        Write-Pass "[$dbName] ExistingReplicationResourcesValidation"
    } else {
        Write-Warn "[$dbName] ExistingReplicationResourcesValidation"
        Write-Host "  -> publications: $($existPub ?? 0), logical slots: $($existSlot ?? 0), subscriptions: $($existSub ?? 0)"

        if (($existPub ?? "0") -ne "0") {
            (Invoke-Src "SELECT pubname, puballtables FROM pg_publication;") | Set-Content (Join-Path $dbDir "existing_publications.txt")
        }
        if (($existSlot ?? "0") -ne "0") {
            (Invoke-Src "SELECT slot_name, plugin, active FROM pg_replication_slots WHERE slot_type = 'logical' AND database = current_database();") | Set-Content (Join-Path $dbDir "existing_slots.txt")
        }
        if (($existSub ?? "0") -ne "0") {
            (Invoke-Tgt "SELECT subname, subenabled, subpublications FROM pg_subscription;") | Set-Content (Join-Path $dbDir "existing_subscriptions.txt")
        }
    }

    Write-Host ""
}

# ════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════
Write-Host "============================================"
Write-Host "  Validation Summary"
Write-Host "============================================"
Write-Host "  Databases : $($Databases -join ', ')"
Write-Host "  Pass      : $script:PassCount"
Write-Host "  Fail      : $script:FailCount"
Write-Host "  Warn      : $script:WarnCount"
Write-Host "  Details   : $WorkDir"
foreach ($dbName in $Databases) {
    Write-Host "              $WorkDir\$dbName\"
}
Write-Host "============================================"

if ($script:FailCount -gt 0) {
    exit 1
}
