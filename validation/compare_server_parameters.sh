#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Azure PostgreSQL Server Parameter Comparison Script
#
# pg_settings 전체를 소스/타겟에서 추출하여 비교합니다.
#   - 양쪽 값이 다른 파라미터
#   - 소스에만 존재 (타겟 버전에서 제거/이름변경된 파라미터)
#   - 타겟에만 존재 (타겟 버전에서 새로 추가된 파라미터)
#
# 실행 시점: 타겟 서버 생성 후, Server parameter 동기화 단계에서 사용
# ============================================================

SRC_HOST="pg-old.postgres.database.azure.com"
SRC_USER="<adminuser>"
SRC_PASS='<password>'

TGT_HOST="pg-new.postgres.database.azure.com"
TGT_USER="<adminuser>"
TGT_PASS='<password>'

# pg_settings는 서버 레벨 시스템 뷰이므로 기본 postgres DB로 접속
SRC_CONN="host=${SRC_HOST} port=5432 dbname=postgres user=${SRC_USER} sslmode=require"
TGT_CONN="host=${TGT_HOST} port=5432 dbname=postgres user=${TGT_USER} sslmode=require"

WORKDIR="./param_compare_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR"

run_src() {
  PGPASSWORD="$SRC_PASS" psql "$SRC_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

run_tgt() {
  PGPASSWORD="$TGT_PASS" psql "$TGT_CONN" -v ON_ERROR_STOP=1 -X -At -c "$1"
}

# ──────────────────────────────────────────────
# 접속 확인
# ──────────────────────────────────────────────
echo "============================================"
echo "  Server Parameter Comparison"
echo "  Source : ${SRC_HOST}"
echo "  Target : ${TGT_HOST}"
echo "  Time   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

if ! PGPASSWORD="$SRC_PASS" psql "$SRC_CONN" -c "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to source. Exiting."
  exit 1
fi
if ! PGPASSWORD="$TGT_PASS" psql "$TGT_CONN" -c "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to target. Exiting."
  exit 1
fi

SRC_VER=$(run_src "SHOW server_version;" 2>/dev/null | xargs)
TGT_VER=$(run_tgt "SHOW server_version;" 2>/dev/null | xargs)
echo "Source version : ${SRC_VER}"
echo "Target version : ${TGT_VER}"
echo ""

# ──────────────────────────────────────────────
# pg_settings 전체 추출 (name|setting|unit|context|source)
# context: 변경 시 재시작 필요 여부를 판단하기 위해 포함
# source: 'default'인지 수동 설정인지 구별하기 위해 포함
# ──────────────────────────────────────────────
PARAM_QUERY="
SELECT name, setting, COALESCE(unit,''), context, source
FROM pg_settings
ORDER BY name;
"

run_src "$PARAM_QUERY" > "$WORKDIR/src_params_raw.txt" 2>/dev/null
run_tgt "$PARAM_QUERY" > "$WORKDIR/tgt_params_raw.txt" 2>/dev/null

# name만 추출 (비교용)
awk -F'|' '{print $1}' "$WORKDIR/src_params_raw.txt" | sort > "$WORKDIR/src_names.txt"
awk -F'|' '{print $1}' "$WORKDIR/tgt_params_raw.txt" | sort > "$WORKDIR/tgt_names.txt"

# ──────────────────────────────────────────────
# 1) 소스에만 존재하는 파라미터 (타겟 버전에서 제거/이름변경)
# ──────────────────────────────────────────────
SRC_ONLY=$(comm -23 "$WORKDIR/src_names.txt" "$WORKDIR/tgt_names.txt")
SRC_ONLY_CNT=$(echo "$SRC_ONLY" | grep -c . 2>/dev/null || echo 0)

echo "── Parameters only in SOURCE (removed/renamed in target version) ──"
if [ "${SRC_ONLY_CNT}" -eq 0 ]; then
  echo "  (none)"
else
  echo "  Count: ${SRC_ONLY_CNT}"
  # 해당 파라미터의 소스 값도 함께 출력
  while IFS= read -r param; do
    [ -z "$param" ] && continue
    val=$(grep "^${param}|" "$WORKDIR/src_params_raw.txt" | head -1)
    setting=$(echo "$val" | awk -F'|' '{print $2}')
    unit=$(echo "$val" | awk -F'|' '{print $3}')
    printf "  %-45s = %s %s\n" "$param" "$setting" "$unit"
  done <<< "$SRC_ONLY"
fi
echo "$SRC_ONLY" > "$WORKDIR/params_source_only.txt" 2>/dev/null
echo ""

# ──────────────────────────────────────────────
# 2) 타겟에만 존재하는 파라미터 (타겟 버전에서 새로 추가)
# ──────────────────────────────────────────────
TGT_ONLY=$(comm -13 "$WORKDIR/src_names.txt" "$WORKDIR/tgt_names.txt")
TGT_ONLY_CNT=$(echo "$TGT_ONLY" | grep -c . 2>/dev/null || echo 0)

echo "── Parameters only in TARGET (new in target version) ──"
if [ "${TGT_ONLY_CNT}" -eq 0 ]; then
  echo "  (none)"
else
  echo "  Count: ${TGT_ONLY_CNT}"
  while IFS= read -r param; do
    [ -z "$param" ] && continue
    val=$(grep "^${param}|" "$WORKDIR/tgt_params_raw.txt" | head -1)
    setting=$(echo "$val" | awk -F'|' '{print $2}')
    unit=$(echo "$val" | awk -F'|' '{print $3}')
    printf "  %-45s = %s %s\n" "$param" "$setting" "$unit"
  done <<< "$TGT_ONLY"
fi
echo "$TGT_ONLY" > "$WORKDIR/params_target_only.txt" 2>/dev/null
echo ""

# ──────────────────────────────────────────────
# 3) 양쪽 모두 존재하지만 값이 다른 파라미터
# ──────────────────────────────────────────────
COMMON=$(comm -12 "$WORKDIR/src_names.txt" "$WORKDIR/tgt_names.txt")
DIFF_COUNT=0

{
  printf "%-45s | %-30s | %-30s | %s\n" "PARAMETER" "SOURCE" "TARGET" "CONTEXT"
  printf "%-45s-+-%-30s-+-%-30s-+-%s\n" "---------------------------------------------" "------------------------------" "------------------------------" "----------"

  while IFS= read -r param; do
    [ -z "$param" ] && continue

    src_line=$(grep "^${param}|" "$WORKDIR/src_params_raw.txt" | head -1)
    tgt_line=$(grep "^${param}|" "$WORKDIR/tgt_params_raw.txt" | head -1)

    src_setting=$(echo "$src_line" | awk -F'|' '{print $2}')
    tgt_setting=$(echo "$tgt_line" | awk -F'|' '{print $2}')
    src_unit=$(echo "$src_line" | awk -F'|' '{print $3}')
    tgt_unit=$(echo "$tgt_line" | awk -F'|' '{print $3}')
    context=$(echo "$src_line" | awk -F'|' '{print $4}')

    if [ "$src_setting" != "$tgt_setting" ]; then
      src_display="${src_setting}"
      [ -n "$src_unit" ] && src_display="${src_display} ${src_unit}"
      tgt_display="${tgt_setting}"
      [ -n "$tgt_unit" ] && tgt_display="${tgt_display} ${tgt_unit}"

      printf "%-45s | %-30s | %-30s | %s\n" "$param" "$src_display" "$tgt_display" "$context"
      DIFF_COUNT=$((DIFF_COUNT + 1))
    fi
  done <<< "$COMMON"
} > "$WORKDIR/params_diff.txt"

echo "── Parameters with DIFFERENT values ──"
if [ "${DIFF_COUNT}" -eq 0 ]; then
  echo "  (none)"
else
  echo "  Count: ${DIFF_COUNT}"
  echo ""
  cat "$WORKDIR/params_diff.txt"
fi
echo ""

# ──────────────────────────────────────────────
# 4) context별 분류 (재시작 필요 여부)
#    postmaster  = 서버 재시작 필요
#    sighup      = reload만 필요
#    superuser   = 세션 단위, superuser 변경 가능
#    user        = 세션 단위, 유저 변경 가능
# ──────────────────────────────────────────────
if [ "${DIFF_COUNT}" -gt 0 ]; then
  echo "── Restart required parameters (context = postmaster) ──"
  RESTART_CNT=0
  while IFS= read -r param; do
    [ -z "$param" ] && continue
    src_line=$(grep "^${param}|" "$WORKDIR/src_params_raw.txt" | head -1)
    tgt_line=$(grep "^${param}|" "$WORKDIR/tgt_params_raw.txt" | head -1)
    src_setting=$(echo "$src_line" | awk -F'|' '{print $2}')
    tgt_setting=$(echo "$tgt_line" | awk -F'|' '{print $2}')
    context=$(echo "$src_line" | awk -F'|' '{print $4}')

    if [ "$src_setting" != "$tgt_setting" ] && [ "$context" = "postmaster" ]; then
      printf "  %-45s  src=%-20s  tgt=%-20s\n" "$param" "$src_setting" "$tgt_setting"
      RESTART_CNT=$((RESTART_CNT + 1))
    fi
  done <<< "$COMMON"
  if [ "${RESTART_CNT}" -eq 0 ]; then
    echo "  (none)"
  else
    echo ""
    echo "  ** ${RESTART_CNT} parameter(s) require SERVER RESTART after change **"
  fi
  echo ""
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo "============================================"
echo "  Parameter Comparison Summary"
echo "============================================"
echo "  Source only (removed/renamed) : ${SRC_ONLY_CNT}"
echo "  Target only (newly added)     : ${TGT_ONLY_CNT}"
echo "  Different values              : ${DIFF_COUNT}"
echo "  Detail files                  : ${WORKDIR}/"
echo "============================================"
echo ""
echo "Files:"
echo "  ${WORKDIR}/src_params_raw.txt          - source pg_settings full dump"
echo "  ${WORKDIR}/tgt_params_raw.txt          - target pg_settings full dump"
echo "  ${WORKDIR}/params_source_only.txt      - parameters only in source"
echo "  ${WORKDIR}/params_target_only.txt      - parameters only in target"
echo "  ${WORKDIR}/params_diff.txt             - parameters with different values"
