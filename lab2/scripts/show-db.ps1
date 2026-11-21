<#
.SYNOPSIS
    Shows what is stored in the single ShopHub database: one schema per microservice + the event bus.

.DESCRIPTION
    Connects with each service's own login role (auth_svc, order_svc, ...), so it also shows
    that a role sees only its own schema. No superuser password is needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\show-db.ps1
    powershell -ExecutionPolicy Bypass -File scripts\show-db.ps1 -Schema orders -Rows 20
#>
param(
    [ValidateSet("all", "auth", "users", "products", "orders", "payments", "notifications", "bus")]
    [string]$Schema = "all",
    [int]$Rows = 5,
    [string]$DbHost = "localhost",
    [int]$Port = 5432,
    [string]$Psql = ""
)

if (-not $Psql) {
    $cmd = Get-Command psql -ErrorAction SilentlyContinue
    if ($cmd) { $Psql = $cmd.Source }
    else {
        $found = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { $Psql = $found.FullName }
    }
}
if (-not $Psql) { Write-Host "psql.exe not found, pass -Psql <path>" -ForegroundColor Red; exit 1 }

$Schemas = [ordered]@{
    "auth"          = @{ Role = "auth_svc"; Service = "auth-service"; Queries = @(
            "SELECT id, email, role, is_active, created_at FROM auth.credentials ORDER BY id DESC LIMIT $Rows") }
    "users"         = @{ Role = "user_svc"; Service = "user-service"; Queries = @(
            "SELECT id, email, full_name, address FROM users.profiles ORDER BY id DESC LIMIT $Rows") }
    "products"      = @{ Role = "product_svc"; Service = "product-service"; Queries = @(
            "SELECT id, name, category, price, stock FROM products.products ORDER BY id LIMIT $Rows") }
    "orders"        = @{ Role = "order_svc"; Service = "order-service"; Queries = @(
            "SELECT id, user_id, status, total_amount, created_at FROM orders.orders ORDER BY id DESC LIMIT $Rows",
            "SELECT order_id, product_name, unit_price, quantity FROM orders.order_items ORDER BY id DESC LIMIT $Rows") }
    "payments"      = @{ Role = "payment_svc"; Service = "payment-service"; Queries = @(
            "SELECT id, order_id, amount, status, failure_reason FROM payments.payments ORDER BY id DESC LIMIT $Rows") }
    "notifications" = @{ Role = "notification_svc"; Service = "notification-service"; Queries = @(
            "SELECT id, user_id, event_type, subject FROM notifications.notifications ORDER BY id DESC LIMIT $Rows") }
    "bus"           = @{ Role = "order_svc"; Service = "event bus (all services)"; Queries = @(
            "SELECT id, event_type, producer, created_at FROM bus.events ORDER BY id DESC LIMIT $Rows",
            "SELECT consumer, last_event_id, updated_at FROM bus.consumer_offsets ORDER BY consumer") }
}

function Invoke-Sql([string]$Role, [string]$Sql) {
    $ErrorActionPreference = "Continue"
    $env:PGPASSWORD = ($Role -replace "_svc$", "_pass")
    $env:LC_MESSAGES = "C"   # English psql messages (avoid broken Cyrillic in the Windows console)
    $out = & $Psql -h $DbHost -p $Port -U $Role -d shophub -P pager=off -c $Sql 2>&1
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    foreach ($line in $out) { Write-Host "    $line" }
}

Write-Host ""
Write-Host "  ONE database 'shophub' on ${DbHost}:${Port} - one schema per microservice" -ForegroundColor Cyan

$targets = if ($Schema -eq "all") { @($Schemas.Keys) } else { @($Schema) }
foreach ($name in $targets) {
    $s = $Schemas[$name]
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host ("  schema {0,-14} owner/role {1,-17} used by {2}" -f $name, $s.Role, $s.Service) -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    foreach ($q in $s.Queries) {
        Write-Host "  $q" -ForegroundColor DarkYellow
        Invoke-Sql $s.Role $q
    }
}

if ($Schema -eq "all") {
    Write-Host ""
    Write-Host "  Isolation check: order_svc tries to read the payments schema" -ForegroundColor Cyan
    Invoke-Sql "order_svc" "SELECT count(*) FROM payments.payments"
}
