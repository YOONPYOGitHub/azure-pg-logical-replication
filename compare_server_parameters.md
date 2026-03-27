# compare_server_parameters — 서버 파라미터 비교 스크립트

소스/타겟의 `pg_settings` 전체를 비교하여 운영 파라미터 동기화를 지원합니다.

마이그레이션 절차의 **2단계 (Target 서버 생성 및 Server parameter 동기화)** 에서 사용합니다.

## 비교 항목

| 구분 | 설명 |
|------|------|
| 값이 다른 파라미터 | 양쪽 모두 존재하지만 setting 값이 다른 것 |
| 소스에만 존재 | 타겟 버전에서 제거되거나 이름이 변경된 파라미터 |
| 타겟에만 존재 | 타겟 버전에서 새로 추가된 파라미터 |
| 재시작 필요 | context=postmaster인 파라미터 별도 표시 |

## 실행

```bash
# Linux / WSL / Cloud Shell
bash validation/compare_server_parameters.sh

# Windows PowerShell
.\validation\compare_server_parameters.ps1

# PowerShell - 호스트 지정
.\validation\compare_server_parameters.ps1 -SrcHost "pg-old.postgres.database.azure.com" -TgtHost "pg-new.postgres.database.azure.com"
```

## 출력 파일

| 파일 | 설명 |
|------|------|
| `src_params_raw.txt` | 소스 pg_settings 전체 덤프 |
| `tgt_params_raw.txt` | 타겟 pg_settings 전체 덤프 |
| `params_source_only.txt` | 소스에만 있는 파라미터 |
| `params_target_only.txt` | 타겟에만 있는 파라미터 |
| `params_diff.txt` | 값이 다른 파라미터 (context 포함) |
