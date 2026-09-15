# Schema / Table Replication Verification Log

## 목적

- 스키마 지정 Publication과 테이블 지정 Publication의 복제 동작 비교
- 선택한 데이터의 초기 복사·DML 반영 및 제외 대상 미복제 확인
- 신규 테이블의 자동 발행 여부와 추가 작업의 차이 확인

## 환경

- **검증일**: 2026-09-15 (UTC)
- **Source / Target**: Azure Database for PostgreSQL Flexible Server 16.15, 서버 2대
- **구성**: Korea Central, `Standard_B2s`, 서버당 32 GiB, HA 없음
- **Source 스키마**: `sales`, `hr`, `internal` — 합성 데이터
- **테스트 DB**: `schema_poc_schema` / `schema_poc_tables`
- **최종 Run ID**: `260915063227120b`
- **실행 시작 / 정리 완료**: 06:32:27 / 06:50:01 (UTC)

> 기존 운영 DB 및 AdventureWorks를 대상으로 실행한 시험은 아닙니다. 선택 범위 설정과 SQL은 [스키마·테이블 단위 선택 복제](schema_replication_poc.md)를 참고하세요.

---

## Step 1: 초기 복제 대상 확인

두 방식 모두 같은 3개 테이블을 초기 대상으로 구성했습니다.

| Source 테이블 | 스키마 지정 방식의 Target | 테이블 지정 방식의 Target |
|--------------|---------------------------|---------------------------|
| `sales.orders` | 초기 100행 일치 | 초기 100행 일치 |
| `sales.events` | 초기 1행 일치 | 초기 1행 일치 |
| `hr.people` | 초기 1행 일치 | 초기 1행 일치 |
| `internal.audit` | 스키마·테이블 없음 | 스키마·테이블 없음 |

### Step 1 결론

- Publication의 실제 테이블 집합이 선택한 3개 테이블과 정확히 일치
- 초기 COPY 이후 행 수·정렬된 전체 행 내용의 MD5 일치 및 구독 테이블 ready 상태 확인
- Azure 관리 역할(`azure_pg_admin` 멤버, `superuser=false`)에서 두 Publication 생성 성공

---

## Step 2: DML 복제 확인

| 테스트 | 스키마 지정 방식 | 테이블 지정 방식 |
|--------|------------------|------------------|
| INSERT / UPDATE / DELETE | 행 수·내용 MD5 일치 | 행 수·내용 MD5 일치 |
| 여러 선택 테이블의 트랜잭션 커밋 | 최종 상태 일치 | 최종 상태 일치 |
| ROLLBACK | 롤백된 행 미반영 | 롤백된 행 미반영 |
| `sales.events` TRUNCATE | 양쪽 0행 | 양쪽 0행 |
| Source `internal.audit` DML | 실행 확인, Target 스키마 없음 | 실행 확인, Target 스키마 없음 |

### Step 2 결론

- 선택한 테이블의 DML 복제 결과는 두 방식에서 동일
- 초기 접속용 임시 Azure 서비스 허용 규칙을 제거하고, 관찰된 Subscriber 단일 IP 허용 및 구독 재연결 후 DML 검증 수행

---

## Step 3: 신규 테이블 처리 차이 확인

Source에 `sales.new_orders`를 생성하여 1행을 넣은 뒤 다음 결과를 확인했습니다.

| 확인 항목 | 스키마 지정 방식 | 테이블 지정 방식 |
|-----------|------------------|------------------|
| 생성 직후 Publication 포함 | **포함** | **미포함** |
| Target 테이블 자동 생성 | 안 됨 | 안 됨 |
| Target DDL 생성 후, REFRESH 전 | 0행·미구독 | 0행·미구독 |
| Source에 필요한 추가 작업 | 없음 | `ADD TABLE sales.new_orders` |
| Target에 필요한 추가 작업 | `REFRESH PUBLICATION` | `REFRESH PUBLICATION` |
| 갱신 후 초기 데이터 | 1행 일치 | 1행 일치 |
| 이후 추가 INSERT | 2행 일치 | 2행 일치 |

### Step 3 결론

**차이는 신규 테이블의 Publication 자동 포함 여부입니다.** 스키마 지정 방식도 Target DDL 생성과 구독 갱신은 별도로 필요합니다.

---

## Step 4: 전환 및 정리 확인

| 확인 항목 | 두 방식의 공통 결과 |
|-----------|---------------------|
| 전환 직전 데이터 | `sales.orders=101`, `sales.events=0`, `hr.people=2`, `sales.new_orders=2`로 양쪽 일치 |
| 전환 직전 시퀀스 | Source 102 / Target 1 — 자동 동기화되지 않음 |
| 시퀀스 수동 보정 후 Target INSERT | ID 103으로 성공, Source에는 해당 행 없음 |
| Subscription 및 복제 슬롯 | 제거 확인 |
| 임시 Azure 리소스 | 배포 보고서 `status=passed`, `cleanup=deleted-and-verified` |

> 시퀀스 보정 후 Target에만 INSERT한 1행은 의도적인 차이이며, 복제 오류가 아닙니다.

---

## 최종 검증 결과

| 방식 | 통과 검사 | 결과 |
|------|-----------|------|
| 스키마 지정 `FOR TABLES IN SCHEMA` | 49개 | **Passed** |
| 테이블 지정 `FOR TABLE` | 49개 | **Passed** |
| 합계 | **98개** | **두 방식 모두 통과** |

초기 데이터와 DML 복제는 동일하게 동작했으며, 신규 테이블의 자동 발행 여부에서 차이를 확인했습니다. 임시 서버 2대를 포함한 전용 리소스 그룹은 삭제 및 부재 확인을 완료했습니다.

> **시험 이력**: 앞선 실행에서는 `pg_dump 17.6`의 PG16 비호환 SET 구문과 Subscription 생성 timeout으로 중단되었습니다. 덤프 헤더 호환성 및 초기 연결 구성을 보완한 뒤 위 최종 실행을 통과했습니다. 앞선 실패 실행의 임시 리소스도 모두 정리했습니다.
>
> **증적**: [복제 검증 스크립트](poc/Test-SchemaReplication.ps1), [합성 테스트 데이터](poc/fixture.sql). 실행별 원본 JSON과 덤프는 로컬 PoC 출력 폴더에 보존하며 Git에서 제외합니다.
>
> **검증 범위**: 소량 합성 데이터의 기능 시험입니다. 운영 데이터 무결성, 파티션·스키마 간 의존성, 성능·지연 SLA 및 HA는 이번 시험에 포함하지 않았습니다.