#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Azure PostgreSQL Logical Replication Pre-Validation Script
#
# DB 배열을 지정하면 서버 레벨 검증은 1회, DB 레벨 검증은 DB별로 수행합니다.
#
# 실행 순서:
#   타겟 서버 생성 → 빈 DB 생성 → 스크립트 실행 → 스키마 마이그레이션 → 데이터 마이그레이션
# ============================================================

# ── 서버 접속 정보 ──
SRC_HOST="pg-old.postgres.database.azure.com"
SRC_USER="<adminuser>"
SRC_PASS='<password>'

TGT_HOST="pg-new.postgres.database.azure.com"
TGT_USER="<adminuser>"
TGT_PASS='<password>'

# ── 마이그레이션 대상 DB 목록 (소스/타겟 동일 이름) ──
DATABASES=("adventureworks" "adventureworks2")

# ── 서버 레벨 접속용 (postgres DB) ──
SRC_SRV_CONN="host=${SRC_HOST} port=5432 dbname=postgres user=${SRC_USER} sslmode=require"
TGT_SRV_CONN="host=${TGT_HOST} port=5432 dbname=postgres user=${TGT_USER} sslmode=require"

WORKDIR="./validation_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR"

# ── 카운터 ──
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
  echo "$1 .......... Succeeded"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "$1 .......... Failed"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  echo "$1 .......... Warning"
  WARN_COUNT=$((WARN_COUNT + 1))
}

# ── 서버 레벨 쿼리 (postgres DB) ──
run_src_srv() {
  PGPASSWORD="$SRC_PASS" psql "$SRC_SRV_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

run_tgt_srv() {
  PGPASSWORD="$TGT_PASS" psql "$TGT_SRV_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

# ── DB 레벨 쿼리 (루프 내에서 CUR_SRC_CONN / CUR_TGT_CONN 사용) ──
run_src() {
  PGPASSWORD="$SRC_PASS" psql "$CUR_SRC_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

run_tgt() {
  PGPASSWORD="$TGT_PASS" psql "$CUR_TGT_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

echo "============================================"
echo "  Migration Pre-Validation"
echo "  Source : ${SRC_HOST}"
echo "  Target : ${TGT_HOST}"
echo "  DBs    : ${DATABASES[*]}"
echo "  Time   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# ════════════════════════════════════════════════
#  Phase 1: 서버 레벨 검증 (postgres DB, 1회 실행)
# ════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 1: Server-Level Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Server Connection ──
if PGPASSWORD="$SRC_PASS" psql "$SRC_SRV_CONN" -c "SELECT 1;" >/dev/null 2>&1 &&
   PGPASSWORD="$TGT_PASS" psql "$TGT_SRV_CONN" -c "SELECT 1;" >/dev/null 2>&1; then
  pass "ServerConnectionValidation"
else
  fail "ServerConnectionValidation"
  echo "  -> Cannot connect to source or target server. Exiting."
  exit 1
fi

# ── 2. VersionCompatibilityValidation ──
SRC_VER=$(run_src_srv "SHOW server_version_num;" 2>/dev/null | xargs)
TGT_VER=$(run_tgt_srv "SHOW server_version_num;" 2>/dev/null | xargs)
SRC_VER_PRETTY=$(run_src_srv "SHOW server_version;" 2>/dev/null | xargs)
TGT_VER_PRETTY=$(run_tgt_srv "SHOW server_version;" 2>/dev/null | xargs)

if [ "${TGT_VER:-0}" -ge "${SRC_VER:-999999}" ]; then
  pass "VersionCompatibilityValidation"
  echo "  -> source: ${SRC_VER_PRETTY:-unknown}, target: ${TGT_VER_PRETTY:-unknown}"
else
  warn "VersionCompatibilityValidation"
  echo "  -> source: ${SRC_VER_PRETTY:-unknown}, target: ${TGT_VER_PRETTY:-unknown}"
  echo "  -> target version is lower than source"
fi

# ── 3. WalLevelValidation ──
WL=$(run_src_srv "SHOW wal_level;" 2>/dev/null | xargs)
if [ "${WL:-}" = "logical" ]; then
  pass "WalLevelValidation"
else
  fail "WalLevelValidation"
  echo "  -> source wal_level: ${WL:-unknown} (expected: logical)"
fi

# ── 4. MaxReplicationSlotsValidation ──
MRS=$(run_src_srv "SHOW max_replication_slots;" 2>/dev/null | xargs)
DB_COUNT=${#DATABASES[@]}
SLOTS_NEEDED=${DB_COUNT}
if [ "${MRS:-0}" -ge "${SLOTS_NEEDED}" ]; then
  pass "MaxReplicationSlotsValidation"
  echo "  -> max_replication_slots: ${MRS:-0} (need >= ${SLOTS_NEEDED} for ${DB_COUNT} DBs)"
else
  fail "MaxReplicationSlotsValidation"
  echo "  -> max_replication_slots: ${MRS:-0} (need >= ${SLOTS_NEEDED} for ${DB_COUNT} DBs)"
fi

# ── 5. MaxWalSendersValidation ──
MWS=$(run_src_srv "SHOW max_wal_senders;" 2>/dev/null | xargs)
if [ "${MWS:-0}" -ge "${SLOTS_NEEDED}" ]; then
  pass "MaxWalSendersValidation"
  echo "  -> max_wal_senders: ${MWS:-0} (need >= ${SLOTS_NEEDED} for ${DB_COUNT} DBs)"
else
  fail "MaxWalSendersValidation"
  echo "  -> max_wal_senders: ${MWS:-0} (need >= ${SLOTS_NEEDED} for ${DB_COUNT} DBs)"
fi

# ── 18. UserRolesValidation ──
run_src_srv "
SELECT rolname FROM pg_roles
WHERE rolname NOT LIKE 'pg_%'
  AND rolname NOT IN ('azure_superuser','azure_pg_admin','replication','azuresu')
ORDER BY 1;
" > "$WORKDIR/src_roles.txt" 2>/dev/null || true

run_tgt_srv "SELECT rolname FROM pg_roles ORDER BY 1;" \
  > "$WORKDIR/tgt_roles.txt" 2>/dev/null || true

MISSING_ROLES=$(comm -23 \
  <(sort "$WORKDIR/src_roles.txt") \
  <(sort "$WORKDIR/tgt_roles.txt") 2>/dev/null)

if [ -z "$MISSING_ROLES" ]; then
  pass "UserRolesValidation"
else
  fail "UserRolesValidation"
  echo "$MISSING_ROLES" > "$WORKDIR/missing_roles.txt"
  echo "  -> roles missing on target:"
  echo "$MISSING_ROLES" | sed 's/^/     /'
fi

# ── 19. TablespaceValidation ──
CUSTOM_TS=$(run_src_srv "
SELECT spcname FROM pg_tablespace
WHERE spcname NOT IN ('pg_default','pg_global')
ORDER BY 1;
" 2>/dev/null | xargs)

if [ -z "${CUSTOM_TS:-}" ]; then
  pass "TablespaceValidation"
else
  warn "TablespaceValidation"
  echo "  -> custom tablespaces: ${CUSTOM_TS}"
fi

# ── 20. ReplicationRoleValidation ──
SRC_REPL=$(run_src_srv "SELECT rolreplication FROM pg_roles WHERE rolname = current_user;" 2>/dev/null | xargs)
if [ "${SRC_REPL:-}" = "t" ]; then
  pass "ReplicationRoleValidation"
else
  fail "ReplicationRoleValidation"
  echo "  -> source user '${SRC_USER}' does not have REPLICATION attribute"
  echo "  -> fix: ALTER ROLE ${SRC_USER} WITH REPLICATION;"
fi

# ── 21. MaxWorkerProcessesValidation ──
SRC_MWP=$(run_src_srv "SHOW max_worker_processes;" 2>/dev/null | xargs)
TGT_MWP=$(run_tgt_srv "SHOW max_worker_processes;" 2>/dev/null | xargs)

MWP_OK=true
[ "${SRC_MWP:-0}" -lt 16 ] && MWP_OK=false
[ "${TGT_MWP:-0}" -lt 16 ] && MWP_OK=false

if [ "$MWP_OK" = "true" ]; then
  pass "MaxWorkerProcessesValidation"
  echo "  -> source: ${SRC_MWP:-unknown}, target: ${TGT_MWP:-unknown}"
else
  warn "MaxWorkerProcessesValidation"
  echo "  -> source: ${SRC_MWP:-unknown}, target: ${TGT_MWP:-unknown} (recommended >= 16)"
fi

echo ""

# ════════════════════════════════════════════════
#  Phase 2: DB-Level Validation (DB별 루프)
# ════════════════════════════════════════════════
validate_database() {
  local DB_NAME="$1"
  local DB_DIR="$WORKDIR/${DB_NAME}"
  mkdir -p "$DB_DIR"

  CUR_SRC_CONN="host=${SRC_HOST} port=5432 dbname=${DB_NAME} user=${SRC_USER} sslmode=require"
  CUR_TGT_CONN="host=${TGT_HOST} port=5432 dbname=${DB_NAME} user=${TGT_USER} sslmode=require"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Phase 2: DB-Level Validation [${DB_NAME}]"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ── 1. ConnectionValidation ──
  if PGPASSWORD="$SRC_PASS" psql "$CUR_SRC_CONN" -c "SELECT 1;" >/dev/null 2>&1 &&
     PGPASSWORD="$TGT_PASS" psql "$CUR_TGT_CONN" -c "SELECT 1;" >/dev/null 2>&1; then
    pass "[${DB_NAME}] ConnectionValidation"
  else
    fail "[${DB_NAME}] ConnectionValidation"
    echo "  -> Cannot connect to ${DB_NAME} on source or target. Skipping this DB."
    return
  fi

  # ── 6. MissingPrimaryKeysValidation ──
  PK_CNT=$(run_src "
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
  " 2>/dev/null | xargs)

  if [ "${PK_CNT:-0}" = "0" ]; then
    pass "[${DB_NAME}] MissingPrimaryKeysValidation"
  else
    fail "[${DB_NAME}] MissingPrimaryKeysValidation"
    echo "  -> tables without PK and without REPLICA IDENTITY FULL/INDEX: ${PK_CNT:-0}"
    echo "  -> fix: add PK or set REPLICA IDENTITY FULL/USING INDEX"
    run_src "
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
    " > "$DB_DIR/missing_primary_keys.txt" 2>/dev/null || true
    echo "  -> detail: $DB_DIR/missing_primary_keys.txt"
  fi

  # ── 7. ExtensionsValidation ──
  run_src "SELECT extname FROM pg_extension ORDER BY 1;" \
    > "$DB_DIR/src_extensions.txt" 2>/dev/null || true
  run_tgt "SELECT name FROM pg_available_extensions ORDER BY 1;" \
    > "$DB_DIR/tgt_available_extensions.txt" 2>/dev/null || true

  MISSING_EXT=$(comm -23 \
    <(sort "$DB_DIR/src_extensions.txt") \
    <(sort "$DB_DIR/tgt_available_extensions.txt") 2>/dev/null)

  if [ -z "$MISSING_EXT" ]; then
    pass "[${DB_NAME}] ExtensionsValidation"
  else
    fail "[${DB_NAME}] ExtensionsValidation"
    echo "$MISSING_EXT" > "$DB_DIR/missing_extensions.txt"
    echo "  -> extensions unavailable on target:"
    echo "$MISSING_EXT" | sed 's/^/     /'
  fi

  # ── 8. LanguageValidation ──
  run_src "SELECT lanname FROM pg_language ORDER BY 1;" \
    > "$DB_DIR/src_languages.txt" 2>/dev/null || true
  run_tgt "SELECT lanname FROM pg_language ORDER BY 1;" \
    > "$DB_DIR/tgt_languages.txt" 2>/dev/null || true

  if diff -q "$DB_DIR/src_languages.txt" "$DB_DIR/tgt_languages.txt" >/dev/null 2>&1; then
    pass "[${DB_NAME}] LanguageValidation"
  else
    fail "[${DB_NAME}] LanguageValidation"
    diff -u "$DB_DIR/src_languages.txt" "$DB_DIR/tgt_languages.txt" \
      > "$DB_DIR/languages_diff.txt" 2>/dev/null || true
    echo "  -> detail: $DB_DIR/languages_diff.txt"
  fi

  # ── 9. LargeObjectValidation ──
  LOB_CNT=$(run_src "SELECT count(*) FROM pg_largeobject_metadata;" 2>/dev/null | xargs)
  if [ "${LOB_CNT:-0}" = "0" ]; then
    pass "[${DB_NAME}] LargeObjectValidation"
  else
    warn "[${DB_NAME}] LargeObjectValidation"
    echo "  -> large objects found: ${LOB_CNT:-0}"
    echo "  -> logical replication does NOT replicate pg_largeobject"
  fi

  # ── 10. EncodingValidation ──
  ENC_SRC=$(run_src "SHOW server_encoding;" 2>/dev/null | xargs)
  ENC_TGT=$(run_tgt "SHOW server_encoding;" 2>/dev/null | xargs)
  if [ "${ENC_SRC:-}" = "${ENC_TGT:-}" ] && [ -n "${ENC_SRC:-}" ]; then
    pass "[${DB_NAME}] EncodingValidation"
  else
    fail "[${DB_NAME}] EncodingValidation"
    echo "  -> source: ${ENC_SRC:-unknown}, target: ${ENC_TGT:-unknown}"
  fi

  # ── 11. CollationsValidation ──
  run_src "
  SELECT collname, collprovider, collcollate, collctype
  FROM pg_collation
  WHERE collnamespace != (SELECT oid FROM pg_namespace WHERE nspname = 'pg_catalog')
  ORDER BY 1;
  " > "$DB_DIR/src_collations.txt" 2>/dev/null || true

  run_tgt "
  SELECT collname, collprovider, collcollate, collctype
  FROM pg_collation
  WHERE collnamespace != (SELECT oid FROM pg_namespace WHERE nspname = 'pg_catalog')
  ORDER BY 1;
  " > "$DB_DIR/tgt_collations.txt" 2>/dev/null || true

  if diff -q "$DB_DIR/src_collations.txt" "$DB_DIR/tgt_collations.txt" >/dev/null 2>&1; then
    pass "[${DB_NAME}] CollationsValidation"
  else
    fail "[${DB_NAME}] CollationsValidation"
    diff -u "$DB_DIR/src_collations.txt" "$DB_DIR/tgt_collations.txt" \
      > "$DB_DIR/collations_diff.txt" 2>/dev/null || true
    echo "  -> detail: $DB_DIR/collations_diff.txt"
  fi

  # ── 12. ReplicaIdentityValidation ──
  RI_CNT=$(run_src "
  SELECT count(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND c.relreplident = 'n';
  " 2>/dev/null | xargs)

  if [ "${RI_CNT:-0}" = "0" ]; then
    pass "[${DB_NAME}] ReplicaIdentityValidation"
  else
    fail "[${DB_NAME}] ReplicaIdentityValidation"
    echo "  -> tables with REPLICA IDENTITY NOTHING: ${RI_CNT:-0}"
    run_src "
    SELECT n.nspname || '.' || c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN ('pg_catalog','information_schema')
      AND c.relreplident = 'n'
    ORDER BY 1;
    " > "$DB_DIR/replica_identity_nothing.txt" 2>/dev/null || true
    echo "  -> detail: $DB_DIR/replica_identity_nothing.txt"
  fi

  # ── 13. SchemaValidation (pg_dump --schema-only) ──
  if PGPASSWORD="$SRC_PASS" pg_dump "$CUR_SRC_CONN" --schema-only --no-owner --no-privileges \
    -f "$DB_DIR/source_schema.sql" >/dev/null 2>&1; then
    pass "[${DB_NAME}] SchemaValidation"
  else
    fail "[${DB_NAME}] SchemaValidation"
  fi

  # ── 14. CreateSchemaValidation ──
  TMP_SCHEMA="validation_tmp_$(date +%s)"
  if PGPASSWORD="$TGT_PASS" psql "$CUR_TGT_CONN" -c "CREATE SCHEMA IF NOT EXISTS ${TMP_SCHEMA};" >/dev/null 2>&1; then
    PGPASSWORD="$TGT_PASS" psql "$CUR_TGT_CONN" -c "DROP SCHEMA IF EXISTS ${TMP_SCHEMA};" >/dev/null 2>&1
    pass "[${DB_NAME}] CreateSchemaValidation"
  else
    fail "[${DB_NAME}] CreateSchemaValidation"
  fi

  # ── 15. SequenceSyncWarning ──
  SEQ_CNT=$(run_src "
  SELECT count(*)
  FROM pg_sequences
  WHERE schemaname NOT IN ('pg_catalog','information_schema');
  " 2>/dev/null | xargs)

  if [ "${SEQ_CNT:-0}" = "0" ]; then
    pass "[${DB_NAME}] SequenceSyncWarning"
  else
    warn "[${DB_NAME}] SequenceSyncWarning"
    echo "  -> sequences found: ${SEQ_CNT:-0}"
    echo "  -> logical replication does NOT sync sequence values"
    run_src "
    SELECT schemaname || '.' || sequencename || ' (last_value=' || COALESCE(last_value::text,'NULL') || ')'
    FROM pg_sequences
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
    ORDER BY 1;
    " > "$DB_DIR/sequences.txt" 2>/dev/null || true
    echo "  -> detail: $DB_DIR/sequences.txt"
  fi

  # ── 16. CreatePublicationValidation ──
  if run_src "CREATE PUBLICATION validation_pub_temp FOR ALL TABLES;" >/dev/null 2>&1 &&
     run_src "DROP PUBLICATION validation_pub_temp;" >/dev/null 2>&1; then
    pass "[${DB_NAME}] CreatePublicationValidation"
  else
    run_src "DROP PUBLICATION IF EXISTS validation_pub_temp;" >/dev/null 2>&1 || true
    fail "[${DB_NAME}] CreatePublicationValidation"
  fi

  # ── 17. RuleEngineValidation ──
  RULE_CNT=$(run_src "SELECT count(*) FROM pg_rules WHERE schemaname NOT IN ('pg_catalog','information_schema');" 2>/dev/null | xargs)
  TRG_CNT=$(run_src "
  SELECT count(*)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname NOT IN ('pg_catalog','information_schema');
  " 2>/dev/null | xargs)

  TGT_TRG_CNT=$(run_tgt "
  SELECT count(*)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname NOT IN ('pg_catalog','information_schema');
  " 2>/dev/null | xargs)

  if [ "${RULE_CNT:-0}" = "0" ] && [ "${TRG_CNT:-0}" = "0" ] && [ "${TGT_TRG_CNT:-0}" = "0" ]; then
    pass "[${DB_NAME}] RuleEngineValidation"
  else
    warn "[${DB_NAME}] RuleEngineValidation"
    echo "  -> source rules: ${RULE_CNT:-0}, source triggers: ${TRG_CNT:-0}"
    echo "  -> target triggers: ${TGT_TRG_CNT:-0}"
    if [ "${TGT_TRG_CNT:-0}" != "0" ]; then
      echo "  -> WARNING: target triggers may fire on replicated rows (double execution)"
      echo "  -> consider: ALTER TABLE ... DISABLE TRIGGER ... on target during replication"
    fi
    run_src "
    SELECT schemaname, tablename, rulename, definition
    FROM pg_rules
    WHERE schemaname NOT IN ('pg_catalog','information_schema')
    ORDER BY 1,2,3;
    " > "$DB_DIR/rules_detail.txt" 2>/dev/null || true

    run_src "
    SELECT n.nspname, c.relname, t.tgname, t.tgenabled
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE NOT t.tgisinternal AND n.nspname NOT IN ('pg_catalog','information_schema')
    ORDER BY 1,2,3;
    " > "$DB_DIR/triggers_detail.txt" 2>/dev/null || true

    if [ "${TGT_TRG_CNT:-0}" != "0" ]; then
      run_tgt "
      SELECT n.nspname, c.relname, t.tgname, t.tgenabled
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT t.tgisinternal AND n.nspname NOT IN ('pg_catalog','information_schema')
      ORDER BY 1,2,3;
      " > "$DB_DIR/target_triggers_detail.txt" 2>/dev/null || true
    fi
  fi

  # ── 22. CreateSubscriptionValidation ──
  TGT_SUB_PERM=$(run_tgt "
  SELECT CASE
    WHEN rolsuper THEN 'true'
    WHEN pg_has_role(current_user, 'azure_pg_admin', 'MEMBER') THEN 'true'
    ELSE 'false'
  END
  FROM pg_roles WHERE rolname = current_user;
  " 2>/dev/null | xargs)

  if [ "${TGT_SUB_PERM:-}" = "true" ]; then
    pass "[${DB_NAME}] CreateSubscriptionValidation"
  else
    fail "[${DB_NAME}] CreateSubscriptionValidation"
    echo "  -> target user '${TGT_USER}' cannot create subscriptions"
    echo "  -> fix: GRANT azure_pg_admin TO ${TGT_USER};"
  fi

  # ── 23. TargetSchemaReadyValidation ──
  SRC_TBL_CNT=$(run_src "
  SELECT count(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema');
  " 2>/dev/null | xargs)

  TGT_TBL_CNT=$(run_tgt "
  SELECT count(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema');
  " 2>/dev/null | xargs)

  if [ "${TGT_TBL_CNT:-0}" -ge "${SRC_TBL_CNT:-0}" ] && [ "${SRC_TBL_CNT:-0}" -gt 0 ]; then
    pass "[${DB_NAME}] TargetSchemaReadyValidation"
    echo "  -> source tables: ${SRC_TBL_CNT}, target tables: ${TGT_TBL_CNT}"
  else
    warn "[${DB_NAME}] TargetSchemaReadyValidation"
    echo "  -> source tables: ${SRC_TBL_CNT:-0}, target tables: ${TGT_TBL_CNT:-0}"
    if [ "${TGT_TBL_CNT:-0}" = "0" ]; then
      echo "  -> target has no user tables yet"
    else
      echo "  -> target has fewer tables than source"
    fi
    echo "  -> run: pg_dump --schema-only | psql target (before data migration step)"
  fi

  # ── 24. ExistingReplicationResourcesValidation ──
  EXIST_PUB=$(run_src "SELECT count(*) FROM pg_publication;" 2>/dev/null | xargs)
  EXIST_SLOT=$(run_src "
  SELECT count(*) FROM pg_replication_slots
  WHERE slot_type = 'logical' AND database = current_database();
  " 2>/dev/null | xargs)
  EXIST_SUB=$(run_tgt "SELECT count(*) FROM pg_subscription;" 2>/dev/null | xargs)

  if [ "${EXIST_PUB:-0}" = "0" ] && [ "${EXIST_SLOT:-0}" = "0" ] && [ "${EXIST_SUB:-0}" = "0" ]; then
    pass "[${DB_NAME}] ExistingReplicationResourcesValidation"
  else
    warn "[${DB_NAME}] ExistingReplicationResourcesValidation"
    echo "  -> publications: ${EXIST_PUB:-0}, logical slots: ${EXIST_SLOT:-0}, subscriptions: ${EXIST_SUB:-0}"

    if [ "${EXIST_PUB:-0}" != "0" ]; then
      run_src "SELECT pubname, puballtables FROM pg_publication;" \
        > "$DB_DIR/existing_publications.txt" 2>/dev/null || true
    fi
    if [ "${EXIST_SLOT:-0}" != "0" ]; then
      run_src "SELECT slot_name, plugin, active FROM pg_replication_slots WHERE slot_type = 'logical' AND database = current_database();" \
        > "$DB_DIR/existing_slots.txt" 2>/dev/null || true
    fi
    if [ "${EXIST_SUB:-0}" != "0" ]; then
      run_tgt "SELECT subname, subenabled, subpublications FROM pg_subscription;" \
        > "$DB_DIR/existing_subscriptions.txt" 2>/dev/null || true
    fi
  fi

  echo ""
}

# ── DB별 검증 실행 ──
for DB in "${DATABASES[@]}"; do
  validate_database "$DB"
done

# ════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════
echo "============================================"
echo "  Validation Summary"
echo "============================================"
echo "  Databases : ${DATABASES[*]}"
echo "  Pass      : $PASS_COUNT"
echo "  Fail      : $FAIL_COUNT"
echo "  Warn      : $WARN_COUNT"
echo "  Details   : $WORKDIR/"
for DB in "${DATABASES[@]}"; do
  echo "              $WORKDIR/${DB}/"
done
echo "============================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi