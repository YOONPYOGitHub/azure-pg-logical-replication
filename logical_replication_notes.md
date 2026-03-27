# PostgreSQL Logical Replication 주의사항 가이드

> 테스트 환경: Azure Database for PostgreSQL Flexible Server  
> 테스트 일자: 2026-03-27  
> DB: `repl_test` (pg-old → pg-new)

---

## 1. PK 없는 테이블의 UPDATE/DELETE 복제

### 문제

Logical Replication에서 UPDATE/DELETE를 복제하려면 **target에서 해당 행을 식별할 수 있어야** 합니다.  
PK가 없는 테이블은 기본 설정(REPLICA IDENTITY DEFAULT)으로는 행을 식별할 수 없어  
**source에서조차 UPDATE/DELETE가 거부**됩니다.

```
ERROR: cannot update table "test_no_pk_nofull" because it does not have a
       replica identity and publishes updates
HINT:  To enable updating the table, set REPLICA IDENTITY using ALTER TABLE.
```

> INSERT는 행 식별이 불필요하므로 어떤 설정이든 정상 동작합니다.

---

### 해결 방법 3가지

#### 방법 1: PK 추가 (권장)

```sql
-- 기존 컬럼 조합으로 PK 추가
ALTER TABLE 테이블명 ADD PRIMARY KEY (col1, col2);

-- 또는 SERIAL 컬럼을 새로 추가하여 PK로 지정
ALTER TABLE 테이블명 ADD COLUMN id SERIAL PRIMARY KEY;
```

- REPLICA IDENTITY = DEFAULT 상태에서 PK를 자동으로 사용
- WAL에 **PK 컬럼만** 기록 → 오버헤드 최소
- 별도의 `ALTER TABLE ... REPLICA IDENTITY` 설정 불필요

#### 방법 2: UNIQUE NOT NULL 인덱스 + REPLICA IDENTITY USING INDEX

```sql
-- 1) UNIQUE 인덱스 생성 (대상 컬럼은 반드시 NOT NULL이어야 함)
CREATE UNIQUE INDEX idx_테이블_col ON 테이블명 (col1);

-- 2) REPLICA IDENTITY를 해당 인덱스로 지정
ALTER TABLE 테이블명 REPLICA IDENTITY USING INDEX idx_테이블_col;

-- 확인
SELECT relname,
       CASE relreplident
           WHEN 'd' THEN 'DEFAULT (PK)'
           WHEN 'f' THEN 'FULL'
           WHEN 'i' THEN 'INDEX'
           WHEN 'n' THEN 'NOTHING'
       END AS replica_identity
FROM pg_class
WHERE relname = '테이블명';
```

- PK를 추가할 수 없는 상황에서 차선책
- WAL에 **인덱스 컬럼만** 기록 → FULL보다 효율적
- 인덱스 컬럼이 **NOT NULL**이어야만 사용 가능

#### 방법 3: REPLICA IDENTITY FULL (비권장)

```sql
-- source(pg-old)에서 실행
ALTER TABLE 테이블명 REPLICA IDENTITY FULL;
```

- PK도 없고, UNIQUE NOT NULL 인덱스도 만들 수 없을 때 사용
- WAL에 **모든 컬럼의 이전 값(old tuple)** 을 기록
- target에서 모든 컬럼 값으로 행을 찾아 UPDATE/DELETE 수행
- **대용량 테이블에서는 성능 부담이 큼** (컬럼이 많을수록 WAL 크기 증가)

---

### 비교 요약

| 방법 | 조건 | WAL 기록량 | target 식별 방식 | 성능 | 설정 위치 |
|---|---|---|---|---|---|
| **PK 추가** | PK 생성 가능 | PK 컬럼만 | PK 값으로 매칭 | 최고 | source |
| **UNIQUE INDEX** | UNIQUE + NOT NULL 컬럼 존재 | 인덱스 컬럼만 | 인덱스 값으로 매칭 | 좋음 | source |
| **FULL** | 조건 없음 | 모든 컬럼 | 전체 컬럼 값 비교 | 느림 | source |

> **설정은 source(pg-old)에서만 하면 됩니다.**  
> WAL에 기록되는 정보량을 결정하는 것이므로 source 측 설정입니다.  
> target(pg-new)에 설정해도 복제에는 영향 없습니다.

---

## 2. 시퀀스(SERIAL/BIGSERIAL) 동기화

### 문제

**Logical Replication은 시퀀스를 복제하지 않습니다.**

행 데이터(row)는 복제되지만, 시퀀스 객체의 `last_value`는 복제되지 않습니다.

```
pg-old (source):  시퀀스 last_value = 10  (id 1~10까지 INSERT됨)
pg-new (target):  시퀀스 last_value = 1   (데이터는 있지만 시퀀스는 초기값)
```

이 상태에서 pg-new에 직접 INSERT하면:

```sql
-- pg-new에서 실행
INSERT INTO test_serial_sync (name, value) VALUES ('new_item', 100);
-- → id = 1 시도 → PK 중복 에러 발생!
-- ERROR: duplicate key value violates unique constraint "test_serial_sync_pkey"
```

---

### 해결: Cutover 시 시퀀스 수동 동기화

마이그레이션 cutover(전환) 시점에 pg-new에서 시퀀스 값을 맞춰줘야 합니다.

#### 개별 시퀀스 동기화

```sql
-- pg-new (target)에서 실행
-- 테이블의 MAX(id) 값으로 시퀀스를 갱신
SELECT setval('test_serial_sync_id_seq', (SELECT MAX(id) FROM test_serial_sync));
SELECT setval('test_bigserial_sync_id_seq', (SELECT MAX(id) FROM test_bigserial_sync));
```

#### 전체 시퀀스 일괄 동기화 (권장)

```sql
-- pg-new (target)에서 실행
-- public 스키마의 모든 SERIAL/BIGSERIAL 시퀀스를 해당 테이블의 MAX 값으로 맞춤
DO $$
DECLARE
    r RECORD;
    max_val BIGINT;
BEGIN
    FOR r IN
        SELECT
            s.sequencename AS seq_name,
            t.tablename AS tbl_name,
            a.attname AS col_name
        FROM pg_sequences s
        JOIN pg_depend d ON d.objid = (s.schemaname || '.' || s.sequencename)::regclass
        JOIN pg_class c ON c.oid = d.refobjid
        JOIN pg_tables t ON t.tablename = c.relname AND t.schemaname = s.schemaname
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
        WHERE s.schemaname = 'public'
          AND d.deptype = 'a'  -- auto dependency (SERIAL)
    LOOP
        EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %I.%I',
                        r.col_name, 'public', r.tbl_name)
                INTO max_val;

        IF max_val > 0 THEN
            EXECUTE format('SELECT setval(%L, %s)', 
                           'public.' || r.seq_name, max_val);
            RAISE NOTICE 'Synced: %.% → %', r.tbl_name, r.seq_name, max_val;
        END IF;
    END LOOP;
END $$;
```

#### 특정 스키마의 시퀀스 동기화 (adventureworks 등)

```sql
-- pg-new (target)에서 실행
-- 원하는 스키마를 지정하여 시퀀스 동기화
DO $$
DECLARE
    r RECORD;
    max_val BIGINT;
    v_schema TEXT;
BEGIN
    -- 시퀀스가 있는 모든 스키마 순회
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
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S'  -- sequence
          AND d.deptype = 'a'  -- auto dependency
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY n.nspname, t.relname
    LOOP
        EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %I.%I',
                        r.col_name, r.schema_name, r.tbl_name)
                INTO max_val;

        IF max_val > 0 THEN
            EXECUTE format('SELECT setval(''%I.%I'', %s)',
                           r.schema_name, r.seq_name, max_val);
            RAISE NOTICE 'Synced: %.%.% → %',
                         r.schema_name, r.tbl_name, r.seq_name, max_val;
        END IF;
    END LOOP;
END $$;
```

---

### 시퀀스 동기화 확인 쿼리

```sql
-- pg-new에서 실행: 시퀀스 last_value vs 테이블 MAX(id) 비교
SELECT
    s.schemaname,
    s.sequencename,
    s.last_value AS seq_value,
    t.tbl_name,
    t.max_id,
    CASE
        WHEN s.last_value >= t.max_id THEN 'OK'
        ELSE 'SYNC NEEDED'
    END AS status
FROM pg_sequences s
JOIN LATERAL (
    SELECT
        c.relname AS tbl_name,
        d.refobjsubid,
        a.attname AS col_name
    FROM pg_depend d
    JOIN pg_class c ON c.oid = d.refobjid
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
    WHERE d.objid = (s.schemaname || '.' || s.sequencename)::regclass
      AND d.deptype = 'a'
    LIMIT 1
) dep ON TRUE
CROSS JOIN LATERAL (
    SELECT COALESCE(MAX(val), 0) AS max_id
    FROM (
        SELECT MAX(col) AS val
        FROM ONLY pg_catalog.pg_class  -- placeholder
    ) sub
) t ON TRUE
WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY s.schemaname, s.sequencename;

-- 간단 버전: 수동으로 확인
SELECT sequencename, last_value
FROM pg_sequences
WHERE schemaname = 'public'
ORDER BY sequencename;
```

---

### Cutover 시 시퀀스 동기화 타이밍

```
1. source(pg-old) 쓰기 중단 (application stop)
2. 복제 지연 0 확인 (pg_stat_replication.replay_lsn = sent_lsn)
3. target(pg-new)에서 시퀀스 동기화 스크립트 실행
4. application을 pg-new로 전환
5. pg-new에서 정상 INSERT 가능 확인
```

> ⚠️ 시퀀스 동기화는 반드시 **쓰기 중단 후, 전환 전**에 수행해야 합니다.  
> 그래야 source의 마지막 시퀀스 값이 target에 정확히 반영됩니다.
