<#
.SYNOPSIS
    Creates the single ShopHub database in the locally installed PostgreSQL (run once).

.DESCRIPTION
    1. Finds psql.exe of the local PostgreSQL installation.
    2. Asks for the password of the PostgreSQL superuser (postgres). The password is
       only passed to psql for this run and is not stored anywhere.
    3. Runs database\01-create-database.sql and database\02-create-schemas.sql:
       database "shophub", 6 login roles, 6 schemas, event bus tables. Safe to re-run.
    4. Checks that a Docker container can reach the database (host.docker.internal).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-database.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup-database.ps1 -Port 5433 -User postgres
#>
param(
    [string]$DbHost = "localhost",
    [int]$Port = 5432,
    [string]$User = "postgres",
    [string]$Psql = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$sqlDir = Join-Path $root "database"

function Write-Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Bad([string]$t) { Write-Host "  [!!] $t" -ForegroundColor Red }

# ---------------------------------------------------------------- 1. psql
if (-not $Psql) {
    $cmd = Get-Command psql -ErrorAction SilentlyContinue
    if ($cmd) { $Psql = $cmd.Source }
    else {
        $found = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { $Psql = $found.FullName }
    }
}
if (-not $Psql -or -not (Test-Path $Psql)) {
    Write-Bad "psql.exe not found. Pass it explicitly: -Psql 'C:\Program Files\PostgreSQL\18\bin\psql.exe'"
    exit 1
}
Write-Ok "psql: $Psql"

# ---------------------------------------------------------------- 2. password
$secure = Read-Host "  Password of PostgreSQL user '$User'" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

function Invoke-Psql([string]$Database, [string]$File) {
    $ErrorActionPreference = "Continue"
    & $Psql -h $DbHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 -q -f $File 2>&1 |
        Where-Object { "$_" -notmatch "NOTICE" } | ForEach-Object { Write-Host "      $_" }
    return $LASTEXITCODE
}

try {
    # ------------------------------------------------------------ 3. SQL
    if ((Invoke-Psql "postgres" (Join-Path $sqlDir "01-create-database.sql")) -ne 0) {
        Write-Bad "Could not create roles / database (wrong password or PostgreSQL not running on ${DbHost}:${Port}?)"
        exit 1
    }
    Write-Ok "database 'shophub' and 6 service roles"
    if ((Invoke-Psql "shophub" (Join-Path $sqlDir "02-create-schemas.sql")) -ne 0) {
        Write-Bad "Could not create schemas"
        exit 1
    }
    Write-Ok "schemas auth, users, products, orders, payments, notifications + event bus (schema bus)"
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 4. reachable from Docker?
Write-Host ""
Write-Host "  Checking that Docker containers can reach the database..."
$ErrorActionPreference = "Continue"
$probe = & docker run --rm --add-host "host.docker.internal:host-gateway" -e PGPASSWORD=auth_pass `
    postgres:18-alpine psql -h host.docker.internal -p $Port -U auth_svc -d shophub -tAc "select 'reachable'" 2>&1
if ("$probe" -match "reachable") {
    Write-Ok "containers can connect to PostgreSQL. Now run:  docker compose up -d --build"
}
else {
    Write-Bad "a container could not connect to your PostgreSQL:"
    Write-Host "      $probe" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  If the message says 'no pg_hba.conf entry', allow connections from Docker:" -ForegroundColor Yellow
    Write-Host "    1. Open (as administrator) C:\Program Files\PostgreSQL\<version>\data\pg_hba.conf"
    Write-Host "    2. Add this line at the end:"
    Write-Host "         host    shophub    all    0.0.0.0/0    scram-sha-256" -ForegroundColor Cyan
    Write-Host "    3. Reload PostgreSQL:  psql -U postgres -c `"select pg_reload_conf()`""
    Write-Host "  If it says 'connection refused', set listen_addresses = '*' in postgresql.conf and restart PostgreSQL."
    Write-Host "  Then run this script again."
}
