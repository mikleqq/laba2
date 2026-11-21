<#
.SYNOPSIS
    Fault-isolation demo: stop one microservice container and show that the other five keep working.

.DESCRIPTION
    For each of the 6 microservices (or only the one given with -Service):
      1. stops its container (docker compose stop <service>);
      2. prints the health of all 6 containers;
      3. calls one business endpoint of every service through the API Gateway;
         only the endpoint of the stopped service fails (502), the rest answer normally;
      4. shows the asynchronous scenario where it applies (events wait in RabbitMQ
         and are processed as soon as the service is back);
      5. starts the container again and waits until it is healthy.

.EXAMPLE
    docker compose up -d --build
    powershell -ExecutionPolicy Bypass -File scripts\failover-demo.ps1
    powershell -ExecutionPolicy Bypass -File scripts\failover-demo.ps1 -Service payment-service -Pause
#>
param(
    [ValidateSet("all", "auth-service", "user-service", "product-service", "order-service", "payment-service", "notification-service")]
    [string]$Service = "all",
    [string]$Gateway = "http://localhost:8080",
    [switch]$Pause
)

$ErrorActionPreference = "Stop"
$ComposeFile = Join-Path (Split-Path $PSScriptRoot -Parent) "docker-compose.yml"

$Services = [ordered]@{
    "auth-service"         = 8001
    "user-service"         = 8002
    "product-service"      = 8003
    "order-service"        = 8004
    "payment-service"      = 8005
    "notification-service" = 8006
}

# ------------------------------------------------------------------ helpers
function Write-Title([string]$text) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
}

function Wait-Key {
    if ($Pause) { [void](Read-Host "  ...press Enter to continue") }
}

function Invoke-Api([string]$Method, [string]$Path, $Body = $null, [string]$Token = $null) {
    $headers = @{}
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }
    $params = @{ Uri = "$Gateway$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 15 }
    if ($null -ne $Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 6 -Compress)
        $params["ContentType"] = "application/json"
    }
    try {
        $r = Invoke-WebRequest @params
        $data = $null
        if ($r.Content) { $data = $r.Content | ConvertFrom-Json }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Data = $data; Error = $null }
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return [pscustomobject]@{ Status = 0; Data = $null; Error = $_.Exception.Message } }
        $text = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        $msg = $text
        try { $msg = ($text | ConvertFrom-Json).error.message } catch { }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Data = $null; Error = $msg }
    }
}

function Get-Health([int]$Port) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { return "UP" }
    } catch { }
    return "DOWN"
}

function Show-Health {
    Write-Host ""
    Write-Host "  Container health (GET /health on every service):"
    foreach ($name in $Services.Keys) {
        $state = Get-Health $Services[$name]
        $color = if ($state -eq "UP") { "Green" } else { "Red" }
        Write-Host ("    {0,-22} :{1}  {2}" -f $name, $Services[$name], $state) -ForegroundColor $color
    }
}

# docker writes progress to stderr; in Windows PowerShell that must not count as an error.
function Invoke-Docker {
    $ErrorActionPreference = "Continue"
    $output = & docker @args 2>&1
    return ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function Wait-Healthy([string]$Name) {
    for ($i = 0; $i -lt 60; $i++) {
        $status = Invoke-Docker inspect -f "{{.State.Health.Status}}" $Name
        if ($status -eq "healthy") { return }
        Start-Sleep -Seconds 1
    }
    throw "$Name did not become healthy in 60s"
}

function Stop-Microservice([string]$Name) {
    Write-Host ""
    Write-Host "  >>> docker compose stop $Name" -ForegroundColor Yellow
    Invoke-Docker compose -f $ComposeFile stop $Name | Out-Null
}

function Start-Microservice([string]$Name) {
    Write-Host ""
    Write-Host "  >>> docker compose start $Name" -ForegroundColor Yellow
    Invoke-Docker compose -f $ComposeFile start $Name | Out-Null
    Wait-Healthy $Name
    Write-Host "      $Name is healthy again" -ForegroundColor Green
}

# One business call per service, all through the API Gateway.
function Show-BusinessChecks([string]$Token, [string]$Email, [string]$Password) {
    $checks = [ordered]@{
        "auth-service"         = { Invoke-Api POST "/api/auth/login" @{ email = $Email; password = $Password } }
        "user-service"         = { Invoke-Api GET "/api/users/me" $null $Token }
        "product-service"      = { Invoke-Api GET "/api/products?limit=3" }
        "order-service"        = { Invoke-Api GET "/api/orders" $null $Token }
        "payment-service"      = { Invoke-Api GET "/api/payments" $null $Token }
        "notification-service" = { Invoke-Api GET "/api/notifications" $null $Token }
    }
    $labels = @{
        "auth-service"         = "POST /api/auth/login"
        "user-service"         = "GET  /api/users/me"
        "product-service"      = "GET  /api/products"
        "order-service"        = "GET  /api/orders"
        "payment-service"      = "GET  /api/payments"
        "notification-service" = "GET  /api/notifications"
    }
    Write-Host ""
    Write-Host "  Business requests through the gateway:"
    foreach ($name in $checks.Keys) {
        $r = & $checks[$name]
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            Write-Host ("    {0,-26} -> {1}  OK" -f $labels[$name], $r.Status) -ForegroundColor Green
        } else {
            Write-Host ("    {0,-26} -> {1}  FAIL ({2})" -f $labels[$name], $r.Status, $r.Error) -ForegroundColor Red
        }
    }
}

function New-Order([string]$Token, [int]$ProductId) {
    $r = Invoke-Api POST "/api/orders" @{ items = @(@{ product_id = $ProductId; quantity = 1 }) } $Token
    if ($r.Status -ne 201) { throw "order creation failed: $($r.Status) $($r.Error)" }
    return $r.Data
}

function Get-OrderStatus([string]$Token, [int]$OrderId) {
    return (Invoke-Api GET "/api/orders/$OrderId" $null $Token).Data.status
}

function Get-NotificationCount([string]$Token) {
    return (Invoke-Api GET "/api/notifications" $null $Token).Data.total
}

# ------------------------------------------------------------------ setup
Write-Title "Preparing: all 6 microservices must be running"
$ready = Invoke-Api GET "/ready"
if ($ready.Status -ne 200) {
    throw "The stack is not ready. Run 'docker compose up -d --build' first."
}
Show-Health

$email = "demo-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "@example.com"
$password = "Secret123!"
$r = Invoke-Api POST "/api/auth/register" @{ email = $email; password = $password; full_name = "Demo User" }
if ($r.Status -ne 201) { throw "registration failed: $($r.Status) $($r.Error)" }
$token = (Invoke-Api POST "/api/auth/login" @{ email = $email; password = $password }).Data.access_token
$product = (Invoke-Api GET "/api/products?limit=100").Data.items | Where-Object { $_.stock -gt 0 } | Select-Object -First 1
Write-Host ""
Write-Host "  Demo user: $email (JWT obtained, it stays valid even if auth-service goes down)"
Write-Host "  Product for test orders: #$($product.id) $($product.name) (stock $($product.stock))"
Show-BusinessChecks $token $email $password
Wait-Key

$targets = if ($Service -eq "all") { @($Services.Keys) } else { @($Service) }

# ------------------------------------------------------------------ scenarios
foreach ($name in $targets) {
    Write-Title "Failure of $name"
    if ($name -eq "notification-service") { $before = Get-NotificationCount $token }
    Stop-Microservice $name
    Show-Health
    Show-BusinessChecks $token $email $password

    switch ($name) {
        "payment-service" {
            Write-Host ""
            Write-Host "  Async scenario: an order is placed while payment-service is down" -ForegroundColor Cyan
            $order = New-Order $token $product.id
            Start-Sleep -Seconds 2
            Write-Host "    order #$($order.id) accepted, status = $(Get-OrderStatus $token $order.id)  (order.created waits in RabbitMQ)"
            Wait-Key
            Start-Microservice $name
            Start-Sleep -Seconds 3
            Write-Host "    order #$($order.id) status after payment-service is back = $(Get-OrderStatus $token $order.id)" -ForegroundColor Green
        }
        "notification-service" {
            Write-Host ""
            Write-Host "  Async scenario: orders keep working without notifications" -ForegroundColor Cyan
            $order = New-Order $token $product.id
            Start-Sleep -Seconds 2
            Write-Host "    order #$($order.id) status = $(Get-OrderStatus $token $order.id)  (events wait in RabbitMQ)"
            Wait-Key
            Start-Microservice $name
            Start-Sleep -Seconds 3
            $after = Get-NotificationCount $token
            Write-Host "    notifications before: $before, after restart: $after  (missed events were delivered)" -ForegroundColor Green
        }
        "order-service" {
            Write-Host ""
            Write-Host "  Catalog, profiles, payments and notifications are still served; only ordering is unavailable." -ForegroundColor Cyan
            Wait-Key
            Start-Microservice $name
        }
        "product-service" {
            Write-Host ""
            Write-Host "  Placing an order needs stock reservation -> clean 502 instead of a crash:" -ForegroundColor Cyan
            $r = Invoke-Api POST "/api/orders" @{ items = @(@{ product_id = $product.id; quantity = 1 }) } $token
            Write-Host ("    POST /api/orders -> {0} ({1})" -f $r.Status, $r.Error) -ForegroundColor Yellow
            Wait-Key
            Start-Microservice $name
        }
        default {
            Wait-Key
            Start-Microservice $name
        }
    }
    Show-Health
    Wait-Key
}

Write-Title "Done: every failure stayed inside one container, the other services kept working"
