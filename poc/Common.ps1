#Requires -Version 7.0
Set-StrictMode -Version Latest

function ConvertTo-PocIdentifier([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Empty SQL identifier.' }
    '"' + $Value.Replace('"', '""') + '"'
}

function ConvertTo-PocLiteral([string]$Value) {
    "'" + $Value.Replace("'", "''") + "'"
}

function Protect-PocText([string]$Text, [string[]]$Secrets) {
    foreach ($secret in $Secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) { $Text = $Text.Replace($secret, '[REDACTED]') }
    }
    $Text
}

function Invoke-PocProcess {
    param(
        [string]$Executable, [string[]]$Arguments, [string]$InputText = '',
        [hashtable]$Environment = @{}, [string[]]$Secrets = @(), [int]$TimeoutSeconds = 180
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command $Executable -ErrorAction Stop).Source
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "$Executable exceeded $TimeoutSeconds seconds."
        }
        $out = $stdout.GetAwaiter().GetResult().Trim()
        $err = $stderr.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw (Protect-PocText "$Executable failed (exit $($process.ExitCode)): $err" $Secrets)
        }
        $out
    } finally { $process.Dispose() }
}

function Invoke-PocPg {
    param([hashtable]$Server, [string]$Database = 'postgres', [string]$Sql)
    # SQL travels over stdin, never in the command line. Password is child-process-only.
    Invoke-PocProcess -Executable psql -Arguments @(
        '-X', '-q', '-A', '-t', '-w', '-v', 'ON_ERROR_STOP=1',
        '-h', $Server.HostName, '-U', $Server.User, '-d', $Database, '-f', '-'
    ) -InputText $Sql -Environment @{
        PGPASSWORD = $Server.Password; PGSSLMODE = 'require'; PGCONNECT_TIMEOUT = '15'
        PGAPPNAME = 'schema-replication-poc'; PGOPTIONS = '-c statement_timeout=120000'
    } -Secrets @($Server.Password, $Server.ReplicationPassword)
}

function Export-PocSchema {
    param([hashtable]$Server, [string]$Database, [string[]]$Schemas, [string]$Path)
    $arguments = @('-h', $Server.HostName, '-U', $Server.User, '-d', $Database, '-w',
        '--schema-only', '--strict-names', '--no-owner', '--no-privileges',
        '--no-publications', '--no-subscriptions', '--file', $Path)
    foreach ($schema in $Schemas) {
        # pg_dump patterns need quoted identifiers to prevent wildcard expansion.
        $arguments += '--schema=' + (ConvertTo-PocIdentifier $schema)
    }
    Invoke-PocProcess -Executable pg_dump -Arguments $arguments -Environment @{
        PGPASSWORD = $Server.Password; PGSSLMODE = 'require'; PGCONNECT_TIMEOUT = '15'
    } -Secrets @($Server.Password) | Out-Null
    # This runner deliberately targets PG16. PG17 pg_dump emits a PG17-only SET even
    # when dumping PG16. Keep the original evidence and normalize ONLY that header.
    $dump = Get-Content $Path -Raw
    $normalized = ConvertTo-PocPg16Dump $dump
    if ($normalized -cne $dump) {
        Copy-Item $Path ($Path + '.original')
        Set-Content -Path $Path -Value $normalized -NoNewline -Encoding utf8
    }
}

function ConvertTo-PocPg16Dump([string]$Dump) {
    if ($Dump -notmatch '(?m)^-- Dumped from database version 16\.') {
        throw 'This fixture runner supports a PG16 source only; use a version-matched dump client.'
    }
    if ($Dump -notmatch '(?m)^-- Dumped by pg_dump version (16|17)\.') {
        throw 'Use pg_dump 16 or 17 for this PG16 fixture; other client versions are not validated.'
    }
    # Do not suppress SQL errors or rewrite user DDL.
    [regex]::Replace($Dump, '(?m)^SET transaction_timeout = 0;\r?\n', '')
}

function Assert-PocEqual([string]$Name, [string]$Expected, [string]$Actual) {
    if ($Expected -cne $Actual) { throw "$Name mismatch. Expected [$Expected], actual [$Actual]." }
}

function Get-PocDigestSql([string]$Schema, [string]$Table) {
    $qualified = (ConvertTo-PocIdentifier $Schema) + '.' + (ConvertTo-PocIdentifier $Table)
    "SELECT jsonb_build_object('count',count(*),'md5',md5(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id)::text,'[]')))::text FROM $qualified t;"
}