# PostgreSQL Logical Replication 마이그레이션 가이드

Azure Database for PostgreSQL Flexible Server 간 **Logical Replication**을 사용한 Online 마이그레이션 Step-by-Step 가이드입니다.

> **환경**
> - Source: `pg-old.postgres.database.azure.com` (PostgreSQL 16)
> - Target: `pg-new.postgres.database.azure.com` (PostgreSQL 16+)
> - 작업 VM: Source/Target 모두 접근 가능한 Linux VM

---

## 전체 흐름

| Step | 작업 | 위치 |
|------|------|------|
| 1 | [Source 서버 설정](#step-1-source-서버-설정-publisher) | Source (Azure Portal + DB) |
| 2 | [Target 서버 준비](#step-2-target-서버-준비) | Target (Azure Portal) |
| 3 | [사전 검증 (Validation)](#step-3-사전-검증-validation) | VM |
| 4 | [Schema dump](#step-4-schema-dump-vm) | VM → Source |
| 5 | [Schema import](#step-5-schema-import-vm) | VM → Target |
| 6 | [Publication 생성](#step-6-publication-생성-source) | Source DB |
| 7 | [Subscription 생성](#step-7-subscription-생성-target) | Target DB |
| 8 | [Initial sync & Replication 상태 확인](#step-8-initial-sync--replication-상태-확인) | Source + Target DB |
| 9 | [데이터 동기화 완료 확인](#step-9-데이터-동기화-완료-확인) | Target DB |
| 10 | [Cutover 준비](#step-10-cutover-준비) | Application |
| 11 | [DB 전환 (DNS)](#step-11-db-전환) | Azure Private DNS |
| 12 | [Application 재시작](#step-12-application-재시작) | Application Server |
| 13 | [Replication 제거](#step-13-replication-제거) | Target + Source DB |

---

## Step 1. Source 서버 설정 (Publisher)

### 1-1. Server parameter 변경

Azure Portal → Source 서버 → **Server parameters**에서 아래 파라미터를 설정합니다.

| 파라미터 | Source | Target | 비고 |
|----------|--------|--------|------|
| `wal_level` | **logical** (필수) | 필요 없음 | Logical Replication의 핵심 설정 |
| `max_worker_processes` | ≥ 16 (권장) | ≥ 16 (권장) | Source/Target 모두 권장 |

> `wal_level`은 Source만 필수입니다.  
> `max_worker_processes`는 Source/Target 모두 16 이상을 권장합니다.  
> 변경 후 **서버 재시작(Restart server)**이 필요합니다.

<img src="img/01. setting_server_parameters.png" width="720" alt="Server parameter 설정">

### 1-2. Replication 권한 확인

Source DB에 접속하여 사용자에게 REPLICATION 권한을 부여합니다.

```sql
-- Source DB에서 실행
ALTER ROLE <adminuser> WITH REPLICATION;
```

> Target이 Source에서 WAL을 읽을 수 있도록 권한을 부여합니다.

<img src="img/04. grant_replication_permissions.png" width="720" alt="Replication 권한 부여">

---

## Step 2. Target 서버 준비

### 2-1. Target Flexible Server 생성

Azure Portal에서 새 PostgreSQL Flexible Server를 생성합니다.

- **버전**: Source version ≤ Target version (동일 또는 상위 버전)
- **예시**: `pg-new.postgres.database.azure.com`, PostgreSQL 16 이상

### 2-2. Server parameter 동기화

Source와 Target의 `pg_settings` 전체를 비교하여 운영 파라미터를 동기화합니다.

```powershell
# Windows PowerShell
.\validation\compare_server_parameters.ps1

# 호스트 지정
.\validation\compare_server_parameters.ps1 `
    -SrcHost "pg-old.postgres.database.azure.com" `
    -TgtHost "pg-new.postgres.database.azure.com"
```

```bash
# Linux / WSL / Cloud Shell
bash validation/compare_server_parameters.sh
```

출력 파일에서 차이를 확인하고 Target에 반영합니다:

| 출력 파일 | 설명 |
|-----------|------|
| `params_diff.txt` | 값이 다른 파라미터 (context 포함) |
| `params_source_only.txt` | Source에만 있는 파라미터 |
| `params_target_only.txt` | Target에만 있는 파라미터 |

> 상세: [compare_server_parameters.md](compare_server_parameters.md)

<img src="img/02. compare_server_parameters.png" width="720" alt="Server parameter 비교">

### 2-3. 복제 대상 Database 생성

Target에 빈 Database를 생성합니다.

```sql
-- Target에서 실행
CREATE DATABASE sourcedb;
```

---

## Step 3. 사전 검증 (Validation)

Logical Replication에 필요한 **24개 검증 항목**을 실행합니다.

```powershell
# Windows PowerShell
.\validation\pre_migration_validation.ps1

# 호스트 + DB 목록 지정
.\validation\pre_migration_validation.ps1 `
    -SrcHost "pg-old.postgres.database.azure.com" `
    -TgtHost "pg-new.postgres.database.azure.com" `
    -Databases "sourcedb"
```

```bash
# Linux / WSL / Cloud Shell
bash validation/pre_migration_validation.sh
```

주요 검증 항목:
- `wal_level = logical` 확인
- `max_replication_slots` ≥ DB 수
- PK 없는 테이블 + REPLICA IDENTITY 미설정 테이블 검출
- Source/Target 확장(Extension) 호환성
- 기존 Publication/Slot/Subscription 충돌 확인

> 상세: [pre_migration_validation.md](pre_migration_validation.md)

<img src="img/03. validation.png" width="720" alt="사전 검증 실행">

---

## Step 4. Schema dump (VM)

작업 VM에서 Source DB의 스키마를 덤프합니다.

```bash
pg_dump \
    -h pg-old.postgres.database.azure.com \
    -U adminuser \
    -d sourcedb \
    --schema-only \
    > schema.sql
```

> `--schema-only` 옵션으로 데이터 없이 스키마만 추출합니다.  
> Logical Replication은 schema를 자동으로 복제하지 않으므로 반드시 먼저 schema를 생성해야 합니다.

<img src="img/05. schema_dump.png" width="720" alt="Schema dump">

---

## Step 5. Schema import (VM)

덤프한 스키마를 Target DB에 적용합니다.

```bash
psql \
    -h pg-new.postgres.database.azure.com \
    -U adminuser \
    -d targetdb \
    -f schema.sql
```

> Source schema = Target schema가 **동일**해야 합니다.  
> Subscription 생성 전에 Target에 테이블이 존재해야 initial data copy가 동작합니다.

<img src="img/06. schema_to_target.png" width="720" alt="Schema를 Target에 적용">

---

## Step 6. Publication 생성 (Source)

Source DB에 접속하여 Publication을 생성합니다.

```sql
-- Source DB에서 실행
psql -h pg-old.postgres.database.azure.com -U adminuser -d sourcedb

CREATE PUBLICATION migration_pub FOR ALL TABLES;
```

> **Publisher** → 변경 데이터를 제공하는 역할입니다.  
> `FOR ALL TABLES`는 모든 테이블을 발행합니다. 특정 테이블만 지정하려면 `FOR TABLE t1, t2`를 사용합니다.

<img src="img/07. publication_generation(source).png" width="720" alt="Publication 생성">

---

## Step 7. Subscription 생성 (Target)

Target DB에 접속하여 Subscription을 생성합니다.

```sql
-- Target DB에서 실행
psql -h pg-new.postgres.database.azure.com -U adminuser -d targetdb

CREATE SUBSCRIPTION migration_sub
    CONNECTION 'host=pg-old.postgres.database.azure.com
    port=5432
    user=adminuser
    password=xxxx
    dbname=sourcedb'
    PUBLICATION migration_pub;
```

> **Subscriber** → Source 데이터를 subscribe(구독)하는 역할입니다.  
> Subscription 생성 시점부터:
> 1. **Initial data copy** (기존 데이터 전체 복사)
> 2. **WAL logical replication** (실시간 변경 사항 스트리밍)
>
> 이 자동으로 시작됩니다.

<img src="img/08. subscription_generation(source).png" width="720" alt="Subscription 생성">

---

## Step 8. Initial sync & Replication 상태 확인

Subscription 생성 후 initial data copy가 완료되면 실시간 WAL 스트리밍이 시작됩니다.

### Source에서 확인

```sql
-- Source DB에서 실행
SELECT * FROM pg_stat_replication;
```

| 확인 항목 | 정상 값 |
|-----------|---------|
| `state` | `streaming` |
| `sent_lsn` = `replay_lsn` | 지연 없음 |

또는:

```sql
-- Replication Slot 상태
SELECT slot_name, active, confirmed_flush_lsn
FROM pg_replication_slots;
```

<img src="img/09. check_replication_status(source).png" width="2160" alt="Replication 상태 확인 (Source)">

### Target에서 확인

```sql
-- Target DB에서 실행
SELECT * FROM pg_stat_subscription;
```

| 확인 항목 | 정상 값 |
|-----------|---------|
| `pid` | 값 존재 (Apply Worker 동작 중) |
| `received_lsn` | 지속 증가 |
| `last_msg_receipt_time` | 최근 시간 |

<img src="img/10. check_replication_status(target).png" width="2160" alt="Replication 상태 확인 (Target)">

### Replication lag 확인

```sql
-- Source에서 실행
SELECT
    application_name,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sent_lsn - replay_lsn AS replication_lag
FROM pg_stat_replication;
```

---

## Step 9. 데이터 동기화 완료 확인

Cutover 전에 데이터 동기화가 완료되었는지 확인합니다.

```sql
-- Target DB에서 실행
SELECT now() - pg_last_xact_replay_timestamp();
```

또는 `pg_stat_subscription`에서 lag이 **0 seconds**인지 확인합니다.

```sql
SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    latest_end_time
FROM pg_stat_subscription;
```

> Lag이 0에 가까우면 Cutover 준비가 된 상태입니다.

---

## Step 10. Cutover 준비

> **중요**: Cutover는 다운타임이 발생합니다.

순서:

| 순서 | 작업 | 설명 |
|------|------|------|
| 1 | Application write 중지 | Application에서 Source DB로의 쓰기 중단 |
| 2 | Source write freeze | Source DB에 새로운 DML이 없는 상태 확인 |
| 3 | Replication lag = 0 확인 | `sent_lsn = replay_lsn` 확인 |

```sql
-- Source에서 lag 최종 확인
SELECT
    application_name,
    sent_lsn,
    replay_lsn,
    sent_lsn - replay_lsn AS lag
FROM pg_stat_replication
WHERE application_name = 'migration_sub';
```

> lag이 0이 되면 Source의 모든 데이터가 Target에 반영된 것입니다.

### 시퀀스 동기화

> ⚠️ Logical Replication은 **시퀀스를 복제하지 않습니다**.  
> Cutover 시점에 Target에서 시퀀스 값을 수동으로 맞춰야 합니다.

```sql
-- Target DB에서 실행: 전체 시퀀스 일괄 동기화
DO $$
DECLARE
    r RECORD;
    max_val BIGINT;
BEGIN
    FOR r IN
        SELECT
            n.nspname AS schema_name,
            s.relname AS seq_name,
            t.relname AS tbl_name,
            a.attname AS col_name
        FROM pg_class s
        JOIN pg_namespace n ON n.oid = s.relnamespace
        JOIN pg_depend d ON d.objid = s.oid
        JOIN pg_class t ON t.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = t.oid
                           AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S'
          AND d.deptype = 'a'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY n.nspname, t.relname
    LOOP
        -- 대상 테이블의 현재 최대 키 값 조회
        EXECUTE format(
            'SELECT COALESCE(MAX(%I), 0) FROM %I.%I',
            r.col_name, r.schema_name, r.tbl_name
        )
        INTO max_val;

        IF max_val > 0 THEN
            -- sequence를 현재 최대 키 값으로 보정
            EXECUTE format(
                'SELECT setval(%L::regclass, %s, true)',
                r.schema_name || '.' || r.seq_name,
                max_val
            );

            -- 보정 결과 출력
            RAISE NOTICE 'Synced: %.% -> %.% = %',
                r.schema_name, r.tbl_name,
                r.schema_name, r.seq_name,
                max_val;
        ELSE
            -- 데이터 없는 테이블은 skip
            RAISE NOTICE 'Skipped empty table: %.% -> %.%',
                r.schema_name, r.tbl_name,
                r.schema_name, r.seq_name;
        END IF;
    END LOOP;
END $$;
```

> 상세: [logical_replication_notes.md](logical_replication_notes.md) — 시퀀스 동기화 섹션

---

## Step 11. DB 전환

Application이 바라보는 DB Endpoint를 Source → Target으로 전환합니다.

### Azure Private DNS 사용 시

DNS alias를 변경하여 Application 코드 수정 없이 전환합니다.

```
# 변경 전
db.krc.internal → pg-old.postgres.database.azure.com

# 변경 후
db.krc.internal → pg-new.postgres.database.azure.com
```

> DNS TTL이 짧게 설정되어 있어야 빠른 전환이 가능합니다.

---

## Step 12. Application 재시작

DB 전환 후 Application을 재시작하여 새 Target으로 연결합니다.

```
# restart application 이후
Application → pg-new
```

> 재시작 후 Target DB에서 정상적 서비스가 되는지 확인합니다.

---

## Step 13. Replication 제거

마이그레이션 완료 후 Replication 리소스를 정리합니다.

### 13-1. Target에서 Subscription 제거

```sql
-- Target DB에서 실행
DROP SUBSCRIPTION migration_sub;
```

> Subscription을 삭제하면 Source의 Replication Slot도 자동으로 삭제됩니다.

<img src="img/11. stop_replication_at_target(target).png" width="720" alt="Target에서 Subscription 제거">

### 13-2. Source에서 Publication 제거

```sql
-- Source DB에서 실행
DROP PUBLICATION migration_pub;
```

<img src="img/12. remove_replication(source).png" width="720" alt="Source에서 Publication 제거">

---

## 관련 문서

| 문서 | 설명 |
|------|------|
| [pre_migration_validation.md](pre_migration_validation.md) | 사전 검증 스크립트 (24개 항목) |
| [compare_server_parameters.md](compare_server_parameters.md) | 서버 파라미터 비교 스크립트 |
| [logical_replication_notes](logical_replication_notes.md) | PK/REPLICA IDENTITY 주의사항, 시퀀스 동기화 |
| [replication_methods_comparison.md](replication_methods_comparison.md) | Logical Replication vs Azure Migration Service 비교 |
| [dml_sync_behavior_comparison.md](dml_sync_behavior_comparison.md) | DML 동기화 동작 차이 및 데이터 정합성 위험 비교 |

## 참고

- [MS Docs: Logical replication and logical decoding](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-logical)
- [MS Docs: Prerequisites for logical replication](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-logical#prerequisites-for-logical-replication-and-logical-decoding)
- [PostgreSQL: Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
