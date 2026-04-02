# Azure Database for PostgreSQL HA + Logical Replication 제약사항

> 출처:
> - [Azure Database for PostgreSQL - Logical Replication Limitations](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-logical#limitations)
> - [PostgreSQL 17 공식 문서 - Logical Replication Failover](https://www.postgresql.org/docs/17/logical-replication-failover.html)
> - [Azure 문서: pg_failover_slots](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-considerations#pg_failover_slots)
>
> PostgreSQL 엔진 수준의 제약(DDL 미복제, 시퀀스 미복제, REPLICA IDENTITY 등)은
> [logical_replication_notes.md](logical_replication_notes.md) 참고

---

## 1. HA Failover 시 Logical Replication Slot 보존

Azure Flexible Server에서 HA(고가용성)를 활성화한 경우, Failover 시 논리 복제 슬롯의 유지 여부가 **PostgreSQL 버전에 따라 다릅니다.**

### 1.1 PostgreSQL 16 이하 — pg_failover_slots 확장 필요

기본적으로 **슬롯이 Failover 시 유실됩니다.** Extension 기반으로 standby에 슬롯을 동기화하는 방식입니다.

**필수 설정:**

| 설정 | 값 | 설명 |
|------|-----|------|
| `shared_preload_libraries` | `pg_failover_slots` 포함 | 서버 시작 시 라이브러리 로드 필수 |
| `hot_standby_feedback` | `on` | standby → primary 피드백 활성화 |

**설정 절차:**

1. Azure Portal → 서버 파라미터에서 `shared_preload_libraries`에 `pg_failover_slots` 추가
2. `hot_standby_feedback = on` 설정
3. 서버 재시작 (shared_preload_libraries 변경 시 필수)

> **PG 16 이하에서 HA + Logical Replication 구성 시 반드시 pg_failover_slots를 활성화하세요.**
> 그렇지 않으면 Failover 이후 슬롯을 재생성하고 subscription을 다시 연결해야 합니다.

### 1.2 PostgreSQL 17 이상 — 네이티브 슬롯 동기화

PostgreSQL 17부터 **슬롯 동기화(slot synchronization)가 엔진에 내장**되었습니다. 별도 확장이 필요 없습니다.

**필수 설정:**

| 설정 | 값 | 위치 | 설명 |
|------|-----|------|------|
| `sync_replication_slots` | `on` | standby | standby가 primary의 논리 슬롯을 동기화 |
| `hot_standby_feedback` | `on` | standby | standby → primary 피드백 활성화 |

**필수 조건 — subscription/slot 생성 시 `failover = true`:**

슬롯 동기화가 동작하려면, subscription 또는 슬롯을 생성할 때 **반드시 `failover` 옵션을 활성화**해야 합니다. 이 옵션이 없으면 파라미터를 켜도 해당 슬롯은 standby에 동기화되지 않습니다.

```sql
-- 방법 1: CREATE SUBSCRIPTION 시 failover 옵션
CREATE SUBSCRIPTION mysub
  CONNECTION 'host=publisher.postgres.database.azure.com ...'
  PUBLICATION mypub
  WITH (failover = true);

-- 방법 2: 슬롯을 수동 생성하는 경우
SELECT pg_create_logical_replication_slot('myslot', 'pgoutput', false, false, true);
-- 마지막 인자 true = failover
```

**권장 설정 — `synchronized_standby_slots`:**

슬롯 동기화는 **비동기**로 동작하므로, Failover 시점에 standby가 subscriber보다 뒤처져 있으면 데이터 유실이 발생할 수 있습니다. 이를 방지하려면:

| 설정 | 위치 | 설명 |
|------|------|------|
| `synchronized_standby_slots` | primary | physical replication slot 이름을 지정하여, 해당 standby에 슬롯이 동기화될 때까지 subscriber에게 데이터 전송을 대기 |

> **정리:** PG 17+에서 HA Failover 슬롯 보존을 위해서는
> 파라미터 설정(`sync_replication_slots`, `hot_standby_feedback`) **+**
> subscription 생성 시 `failover = true` **+**
> (권장) `synchronized_standby_slots` 설정이 필요합니다.

### 1.3 버전별 비교 요약

| 항목 | PostgreSQL 16 이하 | PostgreSQL 17 이상 |
|------|------|------|
| Failover 시 슬롯 보존 | ❌ 기본 유실 | ✅ 자동 보존 (조건 충족 시) |
| 슬롯 보존 방식 | Extension 기반 (`pg_failover_slots`) | 네이티브 (엔진 내장) |
| 필수 파라미터 | `hot_standby_feedback = on` | `sync_replication_slots = on` + `hot_standby_feedback = on` |
| 라이브러리 로드 | `shared_preload_libraries`에 `pg_failover_slots` | 불필요 |
| Subscription 생성 옵션 | 별도 옵션 불필요 | **`failover = true` 필수** |
| 권장 추가 설정 | — | `synchronized_standby_slots` |
| 슬롯 재생성 필요 | 확장 미사용 시 수동 복구 | 조건 충족 시 불필요 |

---

## 2. Failover 후 Subscriber 재접속

슬롯이 보존되더라도, **subscriber가 새 primary에 접속할 수 있어야** 복제가 이어집니다.

Azure Flexible Server의 HA Failover는 **DNS 엔드포인트가 동일하게 유지**됩니다.
→ Subscriber의 connection string에 `.postgres.database.azure.com` 엔드포인트를 사용했다면, **별도 작업 없이** 새 primary에 자동 접속됩니다.