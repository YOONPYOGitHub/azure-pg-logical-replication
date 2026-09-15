#Requires -Version 7.2
# Offline tests only: no Azure calls or database connections.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$count = 0
foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $count++
}
. "$PSScriptRoot/Common.ps1"
Assert-PocEqual 'identifier quoting' '"Odd""Schema"' (ConvertTo-PocIdentifier 'Odd"Schema'); $count++
Assert-PocEqual 'literal quoting' "'O''Reilly'" (ConvertTo-PocLiteral "O'Reilly"); $count++
Assert-PocEqual 'secret redaction' 'a=[REDACTED]; b=[REDACTED]' (Protect-PocText 'a=secret1; b=secret2' @('secret1','secret2')); $count++
$caught = $false
try { Assert-PocEqual 'intentional mismatch' '1' '2' } catch { $caught = $true }
if (-not $caught) { throw 'Assertion did not fail closed.' }; $count++
$caught = $false
try { ConvertTo-PocIdentifier '' } catch { $caught = $true }
if (-not $caught) { throw 'Empty identifier accepted.' }; $count++
$sql = Get-PocDigestSql 'sales' 'orders'
if ($sql -notmatch 'ORDER BY id' -or $sql -notmatch 'FROM "sales"\."orders"') { throw 'Digest query regression.' }; $count++
$out = Invoke-PocProcess -Executable pwsh -Arguments @('-NoProfile','-Command','[Console]::Write([Console]::In.ReadToEnd())') -InputText 'stdin-ok'
Assert-PocEqual 'process stdin' 'stdin-ok' $out; $count++
$out = Invoke-PocProcess -Executable pwsh -Arguments @('-NoProfile','-Command','[Console]::Write($env:POC_TEST_VALUE)') -Environment @{ POC_TEST_VALUE = 'child-only' }
Assert-PocEqual 'child environment' 'child-only' $out
if (Test-Path Env:POC_TEST_VALUE) { throw 'Environment leaked to parent.' }; $count++
$caught = $false
try {
    Invoke-PocProcess -Executable pwsh -Arguments @('-NoProfile','-Command',"[Console]::Error.Write('sensitive-test'); exit 7") -Secrets @('sensitive-test') | Out-Null
} catch {
    $caught = $_.Exception.Message -match 'exit 7' -and $_.Exception.Message -match '\[REDACTED\]' -and $_.Exception.Message -notmatch 'sensitive-test'
}
if (-not $caught) { throw 'Process error/redaction regression.' }; $count++
$header = "-- Dumped from database version 16.15`n-- Dumped by pg_dump version 17.6`n"
$dump = $header + "SET transaction_timeout = 0;`nCREATE SCHEMA sales;`n"
Assert-PocEqual 'PG17 header normalization' ($header + "CREATE SCHEMA sales;`n") (ConvertTo-PocPg16Dump $dump); $count++
$native = "-- Dumped from database version 16.15`n-- Dumped by pg_dump version 16.15`nCREATE SCHEMA sales;`n"
Assert-PocEqual 'PG16 dump unchanged' $native (ConvertTo-PocPg16Dump $native); $count++
$caught = $false
try { ConvertTo-PocPg16Dump ($dump.Replace('database version 16.', 'database version 17.')) } catch { $caught = $true }
if (-not $caught) { throw 'Wrong source version accepted.' }; $count++
$caught = $false
try { ConvertTo-PocPg16Dump ($dump.Replace('pg_dump version 17.', 'pg_dump version 18.')) } catch { $caught = $true }
if (-not $caught) { throw 'Unvalidated dump version accepted.' }; $count++
Write-Host "PASS: $count offline parser/helper/process checks."