# PostgreSQL 스키마·테이블 단위 선택 복제

기존 [DB 전체 복제 가이드](README.md)의 DB-to-DB 연결 구조를 유지하면서, **복제 대상을 특정 스키마 또는 테이블 단위로 세분화하는 방법**을 설명합니다. 기존 단계에서 변경할 부분과 실제 Azure 테스트에서 확인한 동작을 정리합니다.

> **검증 환경**
> - Source / Target: Azure Database for PostgreSQL Flexible Server 16.15, 서버 2대
> - Source: `sales`, `hr`, `internal` 스키마의 합성 데이터
> - 초기 복제 대상: `sales.orders`, `sales.events`, `hr.people`
> - 검증 결과: 두 방식 각각 **49개 검사 통과** — [검증 기록](schema_replication_verification.md)

---

## 복제 범위 지정 방법

| 항목 | 스키마 레벨 복제 | 테이블 레벨 복제 |
|------|------------------|------------------|
| Publication 지정 | `FOR TABLES IN SCHEMA sales, hr` | `FOR TABLE sales.orders, sales.events, hr.people` |
| 선택 기준 | 지정한 스키마에 속한 대상 테이블 | 명시적으로 등록한 대상 테이블 |
| 이번 테스트의 초기 대상 | 3개 테이블 | 동일한 3개 테이블 |
| `sales.new_orders` 신규 생성 시 | **Publication에 자동 포함** | **자동 포함되지 않음** |
| Source의 신규 테이블 등록 | 별도 `ADD TABLE` 불필요 | `ALTER PUBLICATION ... ADD TABLE` 필요 |
| Target의 신규 테이블 준비 | DDL 생성 + `REFRESH PUBLICATION` 필요 | DDL 생성 + `REFRESH PUBLICATION` 필요 |

> **핵심**: DB 전체를 복제하지 않고도 필요한 스키마나 테이블만 선택하여 복제할 수 있습니다. 이번 테스트의 초기 대상은 동일하게 구성했으며, **신규 테이블의 Publication 자동 포함 여부**에서 차이를 확인했습니다. 스키마 지정 방식도 Target의 테이블 생성과 구독 갱신까지 자동 처리하지는 않습니다.

---

## 기존 DB-to-DB 가이드 대비 변경 단계

아래 **Step 번호는 모두 기존 [README.md](README.md)의 번호**입니다. 별도의 마이그레이션 순서를 새로 정의하지 않습니다.

| 기존 단계 | 구분 | 변경 또는 유지할 내용 |
|-----------|------|------------------------|
| [Step 1. Source 서버 설정](README.md#step-1-source-서버-설정-publisher) | 기본 절차 유지 | `wal_level=logical`, 복제 권한·네트워크 등 논리 복제 사전 조건 유지 |
| [Step 2. Target 서버 준비](README.md#step-2-target-서버-준비) | 기본 절차 유지 | Target 서버·DB 준비 유지. 이번 시험에서는 별도 빈 테스트 DB 사용 |
| [Step 3. 사전 검증](README.md#step-3-사전-검증-validation) | **검증 범위 변경** | PK·대상 객체 준비 검사는 실제 발행할 테이블 기준으로 수행. 서버 수준 검사는 유지 |
| [Step 4. Schema dump + Role dump](README.md#step-4-schema-dump--role-dump-vm) | **객체 범위 제한 시 옵션 변경** | Target 객체도 줄일 때 Schema dump 범위를 제한. 이번 시험은 두 방식 모두 `--schema-only --schema=sales --schema=hr` 사용. Role dump는 별도 필요 사항이며 이번 시험에서 미실행 |
| [Step 5. Role import + Schema import](README.md#step-5-role-import--schema-import-vm) | **객체 범위 제한 시 입력 변경** | 준비한 DDL을 복원하는 구조 유지. 이번 시험은 선택 DDL만 적용했으며, 기존 Role import 절차는 미실행 |
| [Step 6. Publication 생성](README.md#step-6-publication-생성-source) | **SQL 변경 — 핵심** | `FOR ALL TABLES` → `FOR TABLES IN SCHEMA ...` 또는 `FOR TABLE ...` |
| [Step 7. Subscription 생성](README.md#step-7-subscription-생성-target) | 기본 구조 유지 | 선택 범위 Publication 구독. 스키마·테이블 필터를 Subscription에 추가하지 않음. 초기 COPY 유지 |
| [Step 8. Replication 상태 확인](README.md#step-8-initial-sync--replication-상태-확인) | **대상 범위 확인 추가** | 해당 구독·슬롯 상태와 함께 Publication의 실제 테이블 집합 및 초기 동기화 ready 상태 확인 |
| [Step 9. 데이터 동기화 완료 확인](README.md#step-9-데이터-동기화-완료-확인) | **완료 판정 보강** | 선택 테이블의 행 수·내용을 비교하고, 제외 대상의 미복제도 확인. 이번 시험은 정렬된 행 내용의 MD5 비교 사용 |
| [Step 10. Cutover 준비](README.md#step-10-cutover-준비) | **시퀀스 처리 범위 변경** | 선택 데이터의 쓰기 종료·일치 확인 후 해당 테이블의 시퀀스 보정. 시험에서는 `sales.orders_id_seq` 보정 후 Target INSERT 확인 |
| [Step 11. DB 전환](README.md#step-11-db-전환) | **이번 시험에서 미검증** | DNS·애플리케이션 연결 전환은 실행하지 않음. 기존 절차를 그대로 적용할 수 있다고 검증한 것은 아님 |
| [Step 12. Application 재시작](README.md#step-12-application-재시작) | **이번 시험에서 미검증** | 애플리케이션 재시작·서비스 동작 검증은 실행하지 않음 |
| [Step 13. Replication 제거](README.md#step-13-replication-제거) | 기본 명령 유지 | 이번 작업의 Subscription·Publication만 제거하고 해당 슬롯 부재 확인 |

> **적용 상태**: 기존 [사전 검증 PowerShell](validation/pre_migration_validation.ps1) 및 [Bash](validation/pre_migration_validation.sh) 스크립트는 수정하지 않았습니다. 위 표는 **기존 절차에 적용할 변경점**이며, 실제 선택 범위 시험은 별도 [검증 스크립트](poc/Test-SchemaReplication.ps1)로 수행했습니다. 스키마 외부 의존 객체는 단순히 검증 범위에서 제외하면 안 되며, 이번 독립 테이블 시험에는 포함되지 않았습니다.
>
> **Step 9 주의**: 기존 예시의 `pg_last_xact_replay_timestamp()`는 물리 복제의 WAL replay 시각이므로 논리 복제 완료 판정에 사용하지 않습니다. 이번 시험에서는 초기 동기화 상태와 실제 선택 데이터의 일치를 확인했습니다. 이 소량 데이터 검사를 운영 대용량 환경의 전체 검증으로 간주하지 않습니다.

---

## 기존 Step 4~5. 초기 객체 준비

두 방식 모두 선택한 `sales`, `hr`의 객체 정의를 추출하여 Target에 먼저 적용했습니다. Source의 `internal` 스키마와 데이터는 그대로 유지했습니다.

> **Dump와 Publication의 역할**
> - `--schema-only`는 **데이터 없이 객체 정의만** 추출하는 옵션입니다.
> - dump는 Target의 초기 객체를 준비하고, Publication은 초기 COPY와 이후 DML의 복제 대상을 결정합니다.
> - **데이터 복제 범위만 제한한다면 Step 4~5의 전체 DDL 준비 방식을 유지할 수 있습니다.** dump 범위와 Publication 범위가 같을 필요는 없지만, 발행 대상 테이블과 필요한 의존 객체는 Target에 있어야 합니다. Target에 생성하는 객체까지 줄이려는 경우 dump 범위도 제한합니다.
> - 이번에는 두 방식의 초기 대상이 같아 **테이블 지정 모드도 스키마 선택 dump를 사용**했습니다. `pg_dump --table`을 사용하는 별도 복원 테스트는 수행하지 않았습니다.

> **Role 처리**: 원격 최신 가이드의 Step 4~5에는 Role dump/import도 포함되어 있습니다. 이번 PoC는 새 테스트 역할을 생성하고 `--no-owner --no-privileges`로 DDL을 추출했으므로, 기존 역할·소유권·GRANT의 이관을 검증한 것은 아닙니다. 운영에서는 필요한 Target 역할과 권한을 별도로 준비해야 합니다.

---

## 기존 Step 6. Publication 범위 변경 (Source)

기존 `FOR ALL TABLES` 대신 다음 두 구문을 **서로 다른 테스트 DB**에서 사용했습니다.

### 6-1. 스키마 레벨 복제

```sql
-- Source의 schema_poc_schema DB에서 실행
CREATE PUBLICATION poc_pub
    FOR TABLES IN SCHEMA sales, hr;
```

`sales`, `hr`의 테이블을 발행하며, 테스트에서 `internal.audit`는 발행 대상에 포함되지 않았습니다.

### 6-2. 테이블 레벨 복제

```sql
-- Source의 schema_poc_tables DB에서 실행
CREATE PUBLICATION poc_pub
    FOR TABLE sales.orders, sales.events, hr.people;
```

등록한 테이블을 발행합니다. 실제 스크립트는 선택 스키마의 테이블 목록을 조회하여 위와 같은 명시적 목록을 생성했습니다.

> **주의**: 기존 Publication에 같은 이름으로 `CREATE`를 다시 실행하는 변경 명령은 아닙니다. 위 구문은 비어 있는 테스트 환경에 새 Publication을 만든 것입니다.

---

## 기존 Step 7. Subscription 기본 구조 유지

Source DB에 연결하여 위 Publication을 구독하고 `copy_data=true`로 초기 데이터를 복사했습니다. **복제 범위를 정하는 변경은 Step 6이며**, Subscription에 별도의 스키마·테이블 선택 옵션을 추가하지 않았습니다.

---

## 추가 작업. 신규 테이블 추가 시 차이 확인

Source의 `sales` 스키마에 `sales.new_orders`를 만들고 1행을 추가했습니다.

| 확인 시점 | 스키마 지정 방식 | 테이블 지정 방식 |
|-----------|------------------|------------------|
| Source 생성 직후 Publication 포함 여부 | 포함 | 미포함 |
| Source 생성 직후 Target 객체 | 없음 | 없음 |
| Target DDL 생성 후, REFRESH 전 | 0행, 미구독 | 0행, 미구독 |

### 스키마 레벨 복제

Source의 Publication에는 이미 포함되어 있으므로 Target에 테이블을 만든 뒤 구독을 갱신합니다.

```sql
-- Target의 schema_poc_schema DB: 테이블 DDL 생성 후 실행
ALTER SUBSCRIPTION poc_sub REFRESH PUBLICATION WITH (copy_data=true);
```

### 테이블 레벨 복제

Target에 테이블을 만든 뒤 Source의 Publication에도 새 테이블을 명시적으로 추가합니다.

```sql
-- Source의 schema_poc_tables DB에서 실행
ALTER PUBLICATION poc_pub ADD TABLE sales.new_orders;
```

```sql
-- Target의 schema_poc_tables DB에서 실행
ALTER SUBSCRIPTION poc_sub REFRESH PUBLICATION WITH (copy_data=true);
```

두 방식 모두 갱신 후 기존 1행이 복사되었으며, Source에 추가로 INSERT한 행까지 Target에 반영되어 **2행으로 일치**했습니다.

---

## 공통 검증 결과

| 항목 | 스키마 지정 방식 | 테이블 지정 방식 |
|------|------------------|------------------|
| 초기 데이터 COPY | 통과 | 통과 |
| INSERT / UPDATE / DELETE | 행 수·전체 행 내용 MD5 일치 | 행 수·전체 행 내용 MD5 일치 |
| 트랜잭션 커밋 / ROLLBACK / TRUNCATE | 통과 | 통과 |
| 제외 스키마 `internal` | Target에 없음 | Target에 없음 |
| 신규 테이블 DDL 자동 생성 | 안 됨 | 안 됨 |
| 시퀀스 상태 자동 동기화 | 안 됨 | 안 됨 |
| 시퀀스 수동 보정 후 Target INSERT | 정상 | 정상 |

> **검증 범위**: PostgreSQL 16.15의 독립적인 일반 테이블과 소량 합성 데이터를 대상으로 확인했습니다. 운영 데이터·파티션·스키마 간 FK/타입 의존성·성능·HA 검증 결과로 확대 해석하지 않습니다.

**결론**: 기존 DB-to-DB 논리 복제 구조에서 복제 범위를 **스키마·테이블 단위로 세분화할 수 있음을 실제 테스트로 확인**했습니다. 선택한 데이터의 DML 복제는 동일하게 동작하며, 신규 테이블은 스키마 지정 시 발행 대상에 자동 포함되고 테이블 지정 시 명시적으로 추가합니다.