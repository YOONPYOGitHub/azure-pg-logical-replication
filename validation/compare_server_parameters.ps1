#Requires -Version 5.1
<#
.SYNOPSIS
    Azure PostgreSQL Server Parameter Comparison Script (PowerShell)
.DESCRIPTION
    pg_settings 전체를 소스/타겟에서 추출하여 비교합니다.
      - 양쪽 값이 다른 파라미터
      - 소스에만 존재 (타겟 버전에서 제거/이름변경된 파라미터)
      - 타겟에만 존재 (타겟 버전에서 새로 추가된 파라미터)

    실행 시점: 타겟 서버 생성 후, Server parameter 동기화 단계에서 사용
.EXAMPLE
    .\compare_server_parameters.ps1
    .\compare_server_parameters.ps1 -SrcHost "pg-old.postgres.database.azure.com" -TgtHost "pg-new.postgres.database.azure.com"
#>

[CmdletBinding()]
param(
    [string]$SrcHost  = "pg-old.postgres.database.azure.com",
    [string]$SrcUser  = "<adminuser>",
    [string]$SrcPass  = '<password>',

    [string]$TgtHost  = "pg-new.postgres.database.azure.com",
    [string]$TgtUser  = "<adminuser>",
    [string]$TgtPass  = '<password>'
)

$ErrorActionPreference = "Continue"

# pg_settings는 서버 레벨 시스템 뷰이므로 기본 postgres DB로 접속
$SrcConn = "host=$SrcHost port=5432 dbname=postgres user=$SrcUser sslmode=require"
$TgtConn = "host=$TgtHost port=5432 dbname=postgres user=$TgtUser sslmode=require"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$WorkDir = Join-Path $PSScriptRoot "param_compare_$timestamp"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Invoke-Src ([string]$Query) {
    $env:PGPASSWORD = $SrcPass
    $result = & psql $SrcConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

function Invoke-Tgt ([string]$Query) {
    $env:PGPASSWORD = $TgtPass
    $result = & psql $TgtConn -v ON_ERROR_STOP=1 -X -At -c $Query 2>$null
    $env:PGPASSWORD = $null
    return $result
}

# ──────────────────────────────────────────────
# 접속 확인
# ──────────────────────────────────────────────
Write-Host "============================================"
Write-Host "  Server Parameter Comparison"
Write-Host "  Source : $SrcHost"
Write-Host "  Target : $TgtHost"
Write-Host "  Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================"
Write-Host ""

$env:PGPASSWORD = $SrcPass
& psql $SrcConn -c "SELECT 1;" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Cannot connect to source. Exiting."; exit 1 }

$env:PGPASSWORD = $TgtPass
& psql $TgtConn -c "SELECT 1;" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Cannot connect to target. Exiting."; exit 1 }
$env:PGPASSWORD = $null

$srcVer = (Invoke-Src "SHOW server_version;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
$tgtVer = (Invoke-Tgt "SHOW server_version;") | ForEach-Object { $_.Trim() } | Select-Object -First 1
Write-Host "Source version : $srcVer"
Write-Host "Target version : $tgtVer"
Write-Host ""

# ──────────────────────────────────────────────
# pg_settings 전체 추출
# ──────────────────────────────────────────────
$paramQuery = @"
SELECT name, setting, COALESCE(unit,''), context, source
FROM pg_settings
ORDER BY name;
"@

$srcRaw = Invoke-Src $paramQuery
$tgtRaw = Invoke-Tgt $paramQuery

$srcRaw | Set-Content (Join-Path $WorkDir "src_params_raw.txt")
$tgtRaw | Set-Content (Join-Path $WorkDir "tgt_params_raw.txt")

# 파싱: name → {setting, unit, context, source}
$srcParams = @{}
foreach ($line in $srcRaw) {
    if (-not $line) { continue }
    $parts = $line.Split('|')
    if ($parts.Count -ge 5) {
        $srcParams[$parts[0]] = @{
            Setting = $parts[1]
            Unit    = $parts[2]
            Context = $parts[3]
            Source  = $parts[4]
        }
    }
}

$tgtParams = @{}
foreach ($line in $tgtRaw) {
    if (-not $line) { continue }
    $parts = $line.Split('|')
    if ($parts.Count -ge 5) {
        $tgtParams[$parts[0]] = @{
            Setting = $parts[1]
            Unit    = $parts[2]
            Context = $parts[3]
            Source  = $parts[4]
        }
    }
}

$srcNames = $srcParams.Keys | Sort-Object
$tgtNames = $tgtParams.Keys | Sort-Object

# ──────────────────────────────────────────────
# 1) 소스에만 존재하는 파라미터 (타겟 버전에서 제거/이름변경)
# ──────────────────────────────────────────────
$srcOnly = $srcNames | Where-Object { $_ -notin $tgtNames }
$srcOnlyCnt = ($srcOnly | Measure-Object).Count

Write-Host "-- Parameters only in SOURCE (removed/renamed in target version) --" -ForegroundColor Yellow
if ($srcOnlyCnt -eq 0) {
    Write-Host "  (none)"
} else {
    Write-Host "  Count: $srcOnlyCnt"
    foreach ($p in $srcOnly) {
        $s = $srcParams[$p]
        $display = "$($s.Setting)"
        if ($s.Unit) { $display += " $($s.Unit)" }
        Write-Host ("  {0,-45} = {1}" -f $p, $display)
    }
}
$srcOnly | Set-Content (Join-Path $WorkDir "params_source_only.txt")
Write-Host ""

# ──────────────────────────────────────────────
# 2) 타겟에만 존재하는 파라미터 (타겟 버전에서 새로 추가)
# ──────────────────────────────────────────────
$tgtOnly = $tgtNames | Where-Object { $_ -notin $srcNames }
$tgtOnlyCnt = ($tgtOnly | Measure-Object).Count

Write-Host "-- Parameters only in TARGET (new in target version) --" -ForegroundColor Cyan
if ($tgtOnlyCnt -eq 0) {
    Write-Host "  (none)"
} else {
    Write-Host "  Count: $tgtOnlyCnt"
    foreach ($p in $tgtOnly) {
        $t = $tgtParams[$p]
        $display = "$($t.Setting)"
        if ($t.Unit) { $display += " $($t.Unit)" }
        Write-Host ("  {0,-45} = {1}" -f $p, $display)
    }
}
$tgtOnly | Set-Content (Join-Path $WorkDir "params_target_only.txt")
Write-Host ""

# ──────────────────────────────────────────────
# 3) 양쪽 모두 존재하지만 값이 다른 파라미터
# ──────────────────────────────────────────────
$common = $srcNames | Where-Object { $_ -in $tgtNames }
$diffLines = @()
$restartLines = @()

foreach ($p in $common) {
    $s = $srcParams[$p]
    $t = $tgtParams[$p]

    if ($s.Setting -ne $t.Setting) {
        $srcDisplay = $s.Setting
        if ($s.Unit) { $srcDisplay += " $($s.Unit)" }
        $tgtDisplay = $t.Setting
        if ($t.Unit) { $tgtDisplay += " $($t.Unit)" }

        $diffLines += [PSCustomObject]@{
            Parameter = $p
            Source    = $srcDisplay
            Target    = $tgtDisplay
            Context   = $s.Context
        }

        if ($s.Context -eq "postmaster") {
            $restartLines += [PSCustomObject]@{
                Parameter = $p
                Source    = $srcDisplay
                Target    = $tgtDisplay
            }
        }
    }
}

$diffCount = $diffLines.Count

Write-Host "-- Parameters with DIFFERENT values --" -ForegroundColor Red
if ($diffCount -eq 0) {
    Write-Host "  (none)"
} else {
    Write-Host "  Count: $diffCount"
    Write-Host ""
    $diffLines | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}

# diff 파일 저장
$diffLines | ForEach-Object {
    "{0,-45} | {1,-30} | {2,-30} | {3}" -f $_.Parameter, $_.Source, $_.Target, $_.Context
} | Set-Content (Join-Path $WorkDir "params_diff.txt")

# ──────────────────────────────────────────────
# 4) context별 분류 (재시작 필요 여부)
# ──────────────────────────────────────────────
if ($restartLines.Count -gt 0) {
    Write-Host "-- Restart required parameters (context = postmaster) --" -ForegroundColor Magenta
    $restartLines | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    Write-Host "  ** $($restartLines.Count) parameter(s) require SERVER RESTART after change **" -ForegroundColor Magenta
    Write-Host ""
}

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
Write-Host "============================================"
Write-Host "  Parameter Comparison Summary"
Write-Host "============================================"
Write-Host "  Source only (removed/renamed) : $srcOnlyCnt"
Write-Host "  Target only (newly added)     : $tgtOnlyCnt"
Write-Host "  Different values              : $diffCount"
Write-Host "  Detail files                  : $WorkDir"
Write-Host "============================================"
Write-Host ""
Write-Host "Files:"
Write-Host "  $WorkDir\src_params_raw.txt          - source pg_settings full dump"
Write-Host "  $WorkDir\tgt_params_raw.txt          - target pg_settings full dump"
Write-Host "  $WorkDir\params_source_only.txt      - parameters only in source"
Write-Host "  $WorkDir\params_target_only.txt      - parameters only in target"
Write-Host "  $WorkDir\params_diff.txt             - parameters with different values"
