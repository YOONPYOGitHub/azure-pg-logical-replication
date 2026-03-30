# DML 동기화 동작 비교: Logical Replication vs Azure Migration Service

> 테스트 환경: Azure Database for PostgreSQL Flexible Server  
> 테스트 일자: 2026-03-30  
> DB: `repl_test` (pg-old → pg-new)

PK 없는 테이블에서 UPDATE/DELETE 시, 두 방식의 **에러 처리와 데이터 정합성**에 결정적 차이가 있습니다.  
이 문서는 해당 차이를 실제 테스트로 검증한 결과입니다.

> **관련 문서**
> - PK/REPLICA IDENTITY 해결 방법: [logical_replication_notes.md](logical_replication_notes.md)
> - 두 방식의 아키텍처 비교: [replication_methods_comparison.md](replication_methods_comparison.md)

---

## 1. 핵심 요약

| 항목 | Logical Replication (pub/sub) | Azure Migration Service |
|------|-------------------------------|------------------------|
| PK 있는 테이블 INSERT/UPDATE/DELETE | ✅ 정상 동기화 | ✅ 정상 동기화 |
| PK 없음 + REPLICA IDENTITY FULL | ✅ 정상 동기화 | ✅ 정상 동기화 |
| PK 없음 + REPLICA IDENTITY DEFAULT | ❌ **Source에서 ERROR** (DML 차단) | ⚠️ **Source 성공, Target 누락** |
| 시퀀스(SERIAL/BIGSERIAL) 동기화 | ❌ 수동 필요 | ⚠️ **Cutover 시 자동 동기화** ¹ |

---

## 2. PK 없는 테이블의 UPDATE/DELETE 동작 차이

### Logical Replication (pub/sub)

`CREATE PUBLICATION`이 존재하면, PostgreSQL 엔진이 DML 실행 시점에 해당 테이블이 publication에 포함되어 있는지 확인합니다.  
Replica identity가 부족하면 **source에서 DML 자체가 거부됩니다** (fail-fast).

```
ERROR: cannot update table "test_no_pk_nofull" because it does not have a
       replica identity and publishes updates
HINT:  To enable updating the table, set REPLICA IDENTITY using ALTER TABLE.
```

- UPDATE → **ERROR** (실행 안 됨)
- DELETE → **ERROR** (실행 안 됨)
- INSERT → 정상 (행 식별 불필요)

### Azure Migration Service

사용자가 직접 publication을 만들지 않습니다.  
Migration Service가 내부적으로 `test_decoding` 플러그인을 사용하여 WAL을 직접 디코딩하므로, source 테이블에는 publication이 걸려있지 않습니다.  
따라서 **source의 UPDATE/DELETE가 아무 에러 없이 성공**합니다.  
그러나 target에서는 해당 변경을 적용할 row를 식별할 수 없어 **동기화가 조용히 누락**됩니다.

- UPDATE → source **성공**, target **미반영**
- DELETE → source **성공**, target **미반영**
- INSERT → source **성공**, target **반영됨**

---

## 3. 위험도 비교

|  | Logical Replication | Azure Migration Service |
|--|---------------------|------------------------|
| 인지 가능성 | ✅ **즉시 에러**로 알 수 있음 | ❌ DML 성공하므로 **문제를 모름** |
| 데이터 정합성 | 에러로 차단되어 **불일치 방지** | source/target **데이터 불일치 발생** |
| 발견 시점 | 즉시 (DML 실행 시) | Cutover 후 (운영 중 데이터 이상 발견) |

> **Azure Migration Service**  
> Source에서는 에러 없이 정상 수행되지만 target에 반영이 안 되어,  
> cutover 후에야 데이터 누락을 발견하게 됩니다.

---

## 4. 실제 테스트 결과

### 테스트 테이블 및 REPLICA IDENTITY 설정

| 테이블 | PK | REPLICA IDENTITY | 비고 |
|--------|-----|-------------------|------|
| test_no_pk | ❌ | **FULL** | PK 없지만 FULL 설정됨 |
| test_no_pk_composite | ❌ | **FULL** | PK 없지만 FULL 설정됨 |
| test_no_pk_nofull | ❌ | **DEFAULT** | PK 없음 + FULL 미설정 (위험) |
| test_serial_sync | ✅ | DEFAULT (PK 사용) | 정상 |
| test_bigserial_sync | ✅ | DEFAULT (PK 사용) | 정상 |

### Azure Migration Service 동기화 결과

#### test_no_pk (REPLICA IDENTITY FULL) — ✅ 정상

| DML | Source | Target | 동기화 |
|-----|--------|--------|--------|
| INSERT (mig_test_1) | ✅ 성공 | ✅ 반영됨 | ✅ |
| UPDATE (nopk_user_1 → mig_updated) | ✅ 성공 | ✅ 반영됨 | ✅ |
| DELETE (nopk_extra_2 삭제) | ✅ 성공 | ✅ 반영됨 | ✅ |

#### test_no_pk_composite (REPLICA IDENTITY FULL) — ✅ 정상

| DML | Source | Target | 동기화 |
|-----|--------|--------|--------|
| INSERT (APAC/mig_product_1) | ✅ 성공 | ✅ 반영됨 | ✅ |
| UPDATE (global_product_1 qty→999) | ✅ 성공 | ✅ 반영됨 | ✅ |
| DELETE (global_product_5 삭제) | ✅ 성공 | ✅ 반영됨 | ✅ |

#### test_no_pk_nofull (REPLICA IDENTITY DEFAULT, PK 없음) — ❌ 불일치 발생

| DML | Source | Target | 동기화 |
|-----|--------|--------|--------|
| INSERT (mig_nofull_1) | ✅ 성공 | ✅ 반영됨 | ✅ |
| UPDATE (user_A → mig_updated/888) | ✅ 성공 | ❌ **미반영** (active/10 유지) | ❌ |
| DELETE (user_C 1건 삭제) | ✅ 성공 | ❌ **미반영** (2건 그대로) | ❌ |

**Source 6행 vs Target 7행 — 데이터 불일치 상태**

```
-- Source (pg-old): 6행
 mig_nofull_1 | active      | 777
 user_A       | mig_updated | 888    ← UPDATE 반영됨
 user_A       | mig_updated | 888
 user_B       | active      |  20
 user_B       | active      |  20
 user_C       | pending     |  30    ← DELETE로 1건 줄었음

-- Target (pg-new): 7행
 mig_nofull_1 | active  | 777
 user_A       | active  |  10    ← UPDATE 미반영!
 user_A       | active  |  10
 user_B       | active  |  20
 user_B       | active  |  20
 user_C       | pending |  30    ← DELETE 미반영!
 user_C       | pending |  30
```

### 시퀀스 동기화 결과

#### CDC 단계 (Cutover 전) — ❌ 미동기화

| 시퀀스 | Source (pg-old) | Target (pg-new) | MAX(id) | 상태 |
|--------|----------------|-----------------|---------|------|
| test_serial_sync_id_seq | **13** | **10** | 13 | ❌ |
| test_bigserial_sync_id_seq | **13** | **10** | 13 | ❌ |
| test_seq_v2_id_seq | **5** | **NULL** (1) | 5 | ❌ |
| test_bigseq_v2_id_seq | **7** | **NULL** (1) | 7 | ❌ |

#### Cutover 완료 후 — 조건부 자동 동기화

| 시퀀스 | Cutover 전 | Cutover 후 | MAX(id) | 상태 |
|--------|-----------|-----------|---------|------|
| test_serial_sync_id_seq | 10 | **13** | 13 | ✅ 자동 동기화됨 |
| test_bigserial_sync_id_seq | 10 | **13** | 13 | ✅ 자동 동기화됨 |
| test_seq_v2_id_seq | NULL (1) | **NULL** (1) | 5 | ❌ 미동기화 |
| test_bigseq_v2_id_seq | NULL (1) | **NULL** (1) | 7 | ❌ 미동기화 |

> ¹ **초기 Migration 생성 시 존재했던 테이블**의 시퀀스만 Cutover 시 자동 `setval()` 수행.  
> CDC 단계에서 수동 추가한 테이블(test_seq_v2, test_bigseq_v2)의 시퀀스는 Cutover 대상에 포함되지 않음.

---

## 5. Migration 전 필수 조치

### PK 없는 테이블 조치

Migration 전에 **모든 PK 없는 테이블**을 점검하고, PK 추가 또는 REPLICA IDENTITY를 설정해야 합니다.

**위험 테이블 검출 쿼리:**

```sql
SELECT
    n.nspname || '.' || c.relname AS table_name,
    CASE c.relreplident
        WHEN 'd' THEN 'DEFAULT (위험!)'
        WHEN 'n' THEN 'NOTHING (위험!)'
        WHEN 'f' THEN 'FULL (OK)'
        WHEN 'i' THEN 'INDEX (OK)'
    END AS replica_identity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_constraint pk
    ON pk.conrelid = c.oid AND pk.contype = 'p'
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND pk.conname IS NULL
  AND c.relreplident NOT IN ('f','i')
ORDER BY table_name;
```

> 조치 방법 (PK 추가 / UNIQUE INDEX / REPLICA IDENTITY FULL)의 상세 비교와 성능 영향은  
> [logical_replication_notes.md](logical_replication_notes.md) §1을 참조하세요.

### 시퀀스 동기화

- **Logical Replication**: 시퀀스 `last_value`를 동기화하지 않습니다. Cutover 시 수동 `setval()` 필수.
- **Azure Migration Service**: Cutover 완료 시 **초기 마이그레이션에 포함된 시퀀스를 자동 동기화**합니다.  
  단, CDC 단계에서 수동 추가된 테이블/시퀀스는 자동 동기화 대상이 아니므로 수동 확인 필요.

> 전체 시퀀스 일괄 동기화 스크립트는  
> [logical_replication_notes.md](logical_replication_notes.md) §2를 참조하세요.

---

## 6. Cutover 체크리스트

PK 없는 테이블과 시퀀스에 대한 핵심 확인 항목입니다.  
전체 Cutover 절차는 [README.md](README.md) Step 10~13을 참조하세요.

```
□ PK 없는 테이블 전수 조사 (위험 테이블 조회 쿼리 실행)
□ 위험 테이블에 PK 추가 또는 REPLICA IDENTITY FULL/INDEX 설정
□ Source/Target 데이터 건수 비교 검증 (특히 PK 없는 테이블)
□ Target에서 시퀀스 동기화 스크립트 실행
□ Target에서 INSERT 정상 수행 확인 (시퀀스 정상 동작)
```

---

## 7. 결론

| 방식 | PK 없는 테이블 UPDATE/DELETE | 에러 인지 | 시퀀스 |
|------|---------------------------|----------|--------|
| **Logical Replication** | 에러로 차단 (안전) | ✅ 즉시 | ❌ 수동 |
| **Azure Migration Service** | 조용히 누락 (위험) | ❌ 모름 | ⚠️ Cutover 시 자동 ¹ |

> **두 방식 모두** PK 없는 테이블 + REPLICA IDENTITY 미설정 시 UPDATE/DELETE 동기화에 문제가 있습니다.  
> 차이점은 Logical Replication은 **에러로 알려주는 반면**, Azure Migration Service는 **모르게 누락**된다는 점입니다.  
> Migration 전에 반드시 PK 없는 테이블을 점검하고 조치해야 합니다.
