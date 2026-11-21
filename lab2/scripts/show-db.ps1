<#
.SYNOPSIS
    Shows the contents of the 6 PostgreSQL databases (one container per microservice).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\show-db.ps1
    powershell -ExecutionPolicy Bypass -File scripts\show-db.ps1 -Service order -Rows 20
#>
param(
    [ValidateSet("all", "auth", "user", "product", "order", "payment", "notification")]
    [string]$Service = "all",
    [int]$Rows = 5
)

$Databases = [ordered]@{
    "auth"         = @{ Port = 5433; Queries = @("SELECT id, email, role, is_active, created_at FROM credentials ORDER BY id DESC LIMIT $Rows") }
    "user"         = @{ Port = 5434; Queries = @("SELECT id, email, full_name, phone, address FROM profiles ORDER BY id DESC LIMIT $Rows") }
    "product"      = @{ Port = 5435; Queries = @("SELECT id, name, category, price, stock FROM products ORDER BY id LIMIT $Rows") }
    "order"        = @{ Port = 5436; Queries = @(
            "SELECT id, user_id, status, total_amount, created_at FROM orders ORDER BY id DESC LIMIT $Rows",
            "SELECT order_id, product_id, product_name, unit_price, quantity FROM order_items ORDER BY id DESC LIMIT $Rows") }
    "payment"      = @{ Port = 5437; Queries = @("SELECT id, order_id, user_id, amount, status, transaction_id FROM payments ORDER BY id DESC LIMIT $Rows") }
    "notification" = @{ Port = 5438; Queries = @("SELECT id, user_id, event_type, subject, is_read FROM notifications ORDER BY id DESC LIMIT $Rows") }
}

function Invoke-Psql([string]$Name, [string]$Sql) {
    $ErrorActionPreference = "Continue"
    $out = & docker exec "$Name-db" psql -U "${Name}_svc" -d "${Name}_db" -P pager=off -c $Sql 2>&1
    foreach ($line in $out) { Write-Host "    $line" }
}

$targets = if ($Service -eq "all") { @($Databases.Keys) } else { @($Service) }
foreach ($name in $targets) {
    $db = $Databases[$name]
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host ("  {0}-service  ->  container {0}-db, database {0}_db  (localhost:{1}, user {0}_svc / {0}_pass)" -f $name, $db.Port) -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host "  Tables and row counts:"
    Invoke-Psql $name "SELECT relname AS table, n_live_tup AS rows FROM pg_stat_user_tables ORDER BY relname"
    foreach ($q in $db.Queries) {
        Write-Host "  $q" -ForegroundColor DarkYellow
        Invoke-Psql $name $q
    }
}
