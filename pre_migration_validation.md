# pre_migration_validation — 사전 검증 스크립트

Logical Replication 방식의 마이그레이션에 필요한 사전 검증 항목을 **마이그레이션 실행 전에** 로컬에서 미리 검증합니다.

> **참고**: Azure Portal의 Migration 서비스와 Logical Replication은 동작 방식이 다릅니다.
> 이 스크립트는 Logical Replication(pgoutput + pg_publication/pg_subscription) 기준으로 최적화되어 있습니다.
> - [MS Docs: Logical replication and logical decoding](https://learn.microsoft.com/en-us/azure/postgresql/configure-maintain/concepts-logical)

## Multi-DB 지원

`DATABASES` 배열(SH) / `$Databases` 파라미터(PS1)에 여러 DB를 지정하면:

- **Phase 1 (Server-Level)**: `postgres` DB로 접속하여 서버 레벨 검증을 **1회** 실행
- **Phase 2 (DB-Level)**: 각 DB별로 DB 레벨 검증을 **반복** 실행

상세 파일은 `validation_<timestamp>/<dbname>/` 하위 디렉토리에 DB별로 생성됩니다.

## 검증 항목 (24개)

### Phase 1: Server-Level (postgres DB, 1회 실행)

| # | 항목 | 대상 | 설명 |
|---|------|------|------|
| - | ServerConnectionValidation | srv | 소스/타겟 서버 접속 확인 |
| 2 | VersionCompatibilityValidation | srv | 타겟 버전 ≥ 소스 버전 |
| 3 | WalLevelValidation | src | wal_level = logical |
| 4 | MaxReplicationSlotsValidation | src | max_replication_slots ≥ DB 수 |
| 5 | MaxWalSendersValidation | src | max_wal_senders ≥ DB 수 |
| 18 | UserRolesValidation | srv | 소스 role이 타겟에 존재 |
| 19 | TablespaceValidation | src | 커스텀 tablespace 사용 여부 |
| 20 | ReplicationRoleValidation | src | 소스 사용자 REPLICATION 권한 확인 |
| 21 | MaxWorkerProcessesValidation | srv | max_worker_processes ≥ 16 (MS Docs 권장) |

### Phase 2: DB-Level (DB별 반복 실행)

| # | 항목 | 대상 | 설명 |
|---|------|------|------|
| 1 | ConnectionValidation | src+tgt | DB별 소스/타겟 접속 확인 |
| 6 | MissingPrimaryKeysValidation | src | PK 없고 REPLICA IDENTITY FULL/INDEX도 아닌 테이블 |
| 7 | ExtensionsValidation | src+tgt | 타겟에서 설치 가능한 확장 |
| 8 | LanguageValidation | src+tgt | 프로시저 언어 비교 |
| 9 | LargeObjectValidation | src | Large Object 존재 여부 (LR 미복제, Warning) |
| 10 | EncodingValidation | src+tgt | server_encoding 일치 |
| 11 | CollationsValidation | src+tgt | Collation 비교 |
| 12 | ReplicaIdentityValidation | src | REPLICA IDENTITY NOTHING 테이블 |
| 13 | SchemaValidation | src | pg_dump --schema-only 가능 여부 |
| 14 | CreateSchemaValidation | tgt | 타겟에 스키마 생성 권한 |
| 15 | SequenceSyncWarning | src | 시퀀스 존재 시 cutover 후 setval() 필요 안내 |
| 16 | CreatePublicationValidation | src | PUBLICATION 생성 권한 |
| 17 | RuleEngineValidation | src+tgt | 소스 Rule/Trigger + **타겟 Trigger 이중 실행** 확인 |
| 22 | CreateSubscriptionValidation | tgt | 타겟 사용자 SUBSCRIPTION 생성 권한 |
| 23 | TargetSchemaReadyValidation | src+tgt | 타겟에 테이블 스키마 사전 존재 확인 |
| 24 | ExistingReplicationResourcesValidation | src+tgt | 기존 Publication/Slot/Subscription 충돌 확인 |

## 사전 조건

1. 타겟 Flexible Server 생성 완료
2. 타겟에 빈 DB 생성 완료 (`CREATE DATABASE <dbname>`)
3. `psql`, `pg_dump` 클라이언트 설치
4. 소스 사용자에 REPLICATION 권한 부여 (`ALTER ROLE <user> WITH REPLICATION;`)
5. `max_worker_processes` ≥ 16 설정 및 서버 재시작 ([MS Docs](https://learn.microsoft.com/en-us/azure/postgresql/configure-maintain/concepts-logical#prerequisites-for-logical-replication-and-logical-decoding))

## 설정

SH 스크립트에서 DB 목록을 수정합니다:

```bash
# pre_migration_validation.sh
DATABASES=("adventureworks" "adventureworks2")
```

PS1 스크립트는 파라미터로 전달합니다:

```powershell
# 기본값 수정 또는 실행 시 지정
$Databases = @("adventureworks", "adventureworks2")
```

## 실행

```bash
# Linux / WSL / Cloud Shell
bash validation/pre_migration_validation.sh

# Windows PowerShell
.\validation\pre_migration_validation.ps1

# PowerShell - 호스트 + DB 목록 지정
.\validation\pre_migration_validation.ps1 -SrcHost "pg-old.postgres.database.azure.com" -TgtHost "pg-new.postgres.database.azure.com" -Databases "adventureworks","adventureworks2"
```

## 출력 예시

```
============================================
  Migration Pre-Validation
  Source : pg-old.postgres.database.azure.com
  Target : pg-new.postgres.database.azure.com
  DBs    : adventureworks, adventureworks2
  Time   : 2026-03-27 06:00:00
============================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase 1: Server-Level Validation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ServerConnectionValidation .......... Succeeded
VersionCompatibilityValidation .......... Succeeded
  -> source: 16.12, target: 17.8
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase 2: DB-Level Validation [adventureworks]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[adventureworks] ConnectionValidation .......... Succeeded
[adventureworks] MissingPrimaryKeysValidation .......... Succeeded
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase 2: DB-Level Validation [adventureworks2]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[adventureworks2] ConnectionValidation .......... Succeeded
...

============================================
  Validation Summary
============================================
  Databases : adventureworks, adventureworks2
  Pass      : 38
  Fail      : 0
  Warn      : 2
  Details   : ./validation_20260327_060000/
              ./validation_20260327_060000/adventureworks/
              ./validation_20260327_060000/adventureworks2/
============================================
```

실패/경고 항목은 `validation_<timestamp>/<dbname>/` 디렉토리에 DB별 상세 파일이 생성됩니다.
