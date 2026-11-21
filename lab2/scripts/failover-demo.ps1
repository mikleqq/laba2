<#
.SYNOPSIS
    Fault-isolation demo for ShopHub: a failure of one microservice never takes the others down.

.DESCRIPTION
    Every microservice is a pair of its own containers: <name>-service + <name>-db.
    Scenarios:
      overview  - show the 6 microservices, their containers and their databases
      stop      - stop a service container (docker compose stop)
      crash     - make the service process crash (exit code 1); Docker restarts it by itself
      database  - stop the service's own database; only this service is affected
      update    - rebuild and redeploy ONE service; no other container is restarted
      all       - everything above

    During each failure the script calls one business endpoint of every service through
    the API Gateway: only the affected service fails, the other five keep answering.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\failover-demo.ps1 -Scenario crash -Service payment-service -Pause
#>
param(
    [ValidateSet("all", "overview", "stop", "crash", "database", "update")]
    [string]$Scenario = "all",
    [ValidateSet("all", "auth-service", "user-service", "product-service", "order-service", "payment-service", "notification-service")]
    [string]$Service = "all",
    [string]$Gateway = "http://localhost:8080",
    [string]$InternalToken = "dev-internal-token-change-me",
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

# ================================================================== output helpers
function Write-Title([string]$text) {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor DarkGray
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor DarkGray
}

function Write-Step([string]$text) { Write-Host ""; Write-Host "  $text" -ForegroundColor Cyan }
function Write-Cmd([string]$text) { Write-Host ""; Write-Host "  >>> $text" -ForegroundColor Yellow }

function Wait-Key {
    if ($Pause) { [void](Read-Host "  ...press Enter to continue") }
}

function Get-DbName([string]$ServiceName) { return ($ServiceName -replace "-service$", "-db") }

# ================================================================== docker helpers
# docker writes progress to stderr; in Windows PowerShell that must not count as an error.
function Invoke-Docker {
    $ErrorActionPreference = "Continue"
    $output = & docker @args 2>&1
    return ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function Get-ContainerState([string]$Name) {
    $raw = Invoke-Docker inspect -f "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.State.StartedAt}}" $Name
    if (-not $raw) { return [pscustomobject]@{ Status = "missing"; Health = ""; Restarts = 0; StartedAt = "" } }
    $p = "$raw".Split("|")
    return [pscustomobject]@{ Status = $p[0]; Health = $p[1]; Restarts = [int]$p[2]; StartedAt = $p[3] }
}

function Wait-Healthy([string]$Name, [int]$Seconds = 90) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if ((Get-ContainerState $Name).Health -eq "healthy") { return }
        Start-Sleep -Seconds 1
    }
    throw "$Name did not become healthy in $Seconds s"
}

function Invoke-Compose([string[]]$Arguments) {
    Write-Cmd ("docker compose " + ($Arguments -join " "))
    Invoke-Docker compose -f $ComposeFile @Arguments | Out-Null
}

# ================================================================== http helpers
function Invoke-Api([string]$Method, [string]$Url, $Body = $null, [hashtable]$Headers = @{}) {
    $params = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 15 }
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
        $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        try { $msg = ($msg | ConvertFrom-Json).error.message } catch { }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Data = $null; Error = $msg }
    }
}

function Api([string]$Method, [string]$Path, $Body = $null) {
    return Invoke-Api $Method "$Gateway$Path" $Body @{ Authorization = "Bearer $script:Token" }
}

function Get-Probe([int]$Port, [string]$Path) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port$Path" -UseBasicParsing -TimeoutSec 2
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# ================================================================== views
function Show-Overview {
    Write-Host ""
    Write-Host ("  {0,-22} {1,-24} {2,-20} {3}" -f "MICROSERVICE", "SERVICE CONTAINER", "OWN DATABASE", "API")
    foreach ($name in $Services.Keys) {
        $port = $Services[$name]
        $svc = Get-ContainerState $name
        $db = Get-ContainerState (Get-DbName $name)
        $live = Get-Probe $port "/health"
        $ready = Get-Probe $port "/ready"
        $svcText = if ($svc.Status -eq "running") { "running ($($svc.Health))" } else { $svc.Status }
        $dbText = if ($db.Status -eq "running") { "running ($($db.Health))" } else { $db.Status }
        $apiText = if ($live -ne 200) { "DOWN" } elseif ($ready -ne 200) { "UP, not ready (no DB)" } else { "UP" }
        $color = if ($apiText -eq "UP") { "Green" } elseif ($apiText -eq "DOWN") { "Red" } else { "Yellow" }
        Write-Host ("  {0,-22} {1,-24} {2,-20} {3}" -f $name, $svcText, $dbText, $apiText) -ForegroundColor $color
    }
}

$CheckLabels = [ordered]@{
    "auth-service"         = "POST /api/auth/login"
    "user-service"         = "GET  /api/users/me"
    "product-service"      = "GET  /api/products"
    "order-service"        = "GET  /api/orders"
    "payment-service"      = "GET  /api/payments"
    "notification-service" = "GET  /api/notifications"
}

function Invoke-BusinessCheck([string]$Name) {
    switch ($Name) {
        "auth-service"         { return Invoke-Api POST "$Gateway/api/auth/login" @{ email = $script:Email; password = $script:Password } }
        "user-service"         { return Api GET "/api/users/me" }
        "product-service"      { return Invoke-Api GET "$Gateway/api/products?limit=3" }
        "order-service"        { return Api GET "/api/orders" }
        "payment-service"      { return Api GET "/api/payments" }
        "notification-service" { return Api GET "/api/notifications" }
    }
}

function Show-BusinessChecks {
    Write-Host ""
    Write-Host "  The shop through the API Gateway (one request per microservice):"
    foreach ($name in $CheckLabels.Keys) {
        $r = Invoke-BusinessCheck $name
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            Write-Host ("    {0,-27} -> {1}  OK" -f $CheckLabels[$name], $r.Status) -ForegroundColor Green
        } else {
            Write-Host ("    {0,-27} -> {1}  FAIL: {2}" -f $CheckLabels[$name], $r.Status, $r.Error) -ForegroundColor Red
        }
    }
}

function New-Order {
    $r = Api POST "/api/orders" @{ items = @(@{ product_id = $script:ProductId; quantity = 1 }) }
    if ($r.Status -ne 201) { throw "order creation failed: $($r.Status) $($r.Error)" }
    return $r.Data
}

function Get-OrderStatus([int]$OrderId) { return (Api GET "/api/orders/$OrderId").Data.status }

function Wait-OrderStatus([int]$OrderId, [string]$Expected, [int]$Seconds = 30) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        $status = Get-OrderStatus $OrderId
        if ($status -eq $Expected) { return $status }
        Start-Sleep -Seconds 1
    }
    return Get-OrderStatus $OrderId
}

# ================================================================== scenarios
function Invoke-StopScenario([string]$Name) {
    Write-Title "STOP: container $Name is switched off"
    Invoke-Compose @("stop", $Name)
    Show-Overview
    Show-BusinessChecks
    if ($Name -eq "payment-service") {
        Write-Step "Order placed while payment-service is off:"
        $order = New-Order
        Write-Host "    order #$($order.id) accepted, status = $($order.status) (order.created waits in RabbitMQ)"
    }
    Wait-Key
    Invoke-Compose @("start", $Name)
    Wait-Healthy $Name
    Write-Host "    $Name is healthy again" -ForegroundColor Green
    if ($Name -eq "payment-service") {
        Write-Host "    order #$($order.id) status now = $(Wait-OrderStatus $order.id 'paid')" -ForegroundColor Green
    }
    Wait-Key
}

function Invoke-CrashScenario([string]$Name) {
    Write-Title "CRASH: the process of $Name dies (exit code 1)"
    $before = (Get-ContainerState $Name).Restarts
    Write-Cmd "POST http://localhost:$($Services[$Name])/chaos/crash   (simulated fatal error inside the service)"
    $r = Invoke-Api POST "http://localhost:$($Services[$Name])/chaos/crash" $null @{ "X-Internal-Token" = $InternalToken }
    if ($r.Status -ne 200) { throw "crash endpoint failed: $($r.Status) $($r.Error) (is CHAOS_ENABLED=true?)" }
    Start-Sleep -Milliseconds 400
    Show-BusinessChecks
    Show-Overview
    Wait-Key
    Write-Step "Nobody touches anything: Docker restarts the crashed container itself (restart: unless-stopped)"
    for ($i = 0; $i -lt 30 -and (Get-ContainerState $Name).Restarts -le $before; $i++) { Start-Sleep -Seconds 1 }
    Wait-Healthy $Name
    $after = (Get-ContainerState $Name).Restarts
    Write-Host "    restart count of ${Name}: $before -> $after, healthy again" -ForegroundColor Green
    Show-Overview
    Wait-Key
}

function Invoke-DatabaseScenario([string]$Name) {
    $db = Get-DbName $Name
    Write-Title "DATABASE FAILURE: $db (the database of $Name only) goes down"
    Invoke-Compose @("stop", $db)
    Start-Sleep -Seconds 2
    Show-Overview
    Write-Host "    -> $Name itself is alive (/health 200) but not ready (/ready 503); other databases are untouched" -ForegroundColor Yellow
    Show-BusinessChecks
    $order = $null
    if ($Name -eq "payment-service") {
        Write-Step "Order placed while payment-db is down:"
        $order = New-Order
        Start-Sleep -Seconds 2
        Write-Host "    order #$($order.id) accepted, status = $(Get-OrderStatus $order.id) (payment is retried every 5 s)"
    }
    Wait-Key
    Invoke-Compose @("start", $db)
    Wait-Healthy $db
    for ($i = 0; $i -lt 30 -and (Get-Probe $Services[$Name] "/ready") -ne 200; $i++) { Start-Sleep -Seconds 1 }
    Write-Host "    $db is back, $Name is ready again without a restart" -ForegroundColor Green
    if ($order) {
        Write-Host "    order #$($order.id) status now = $(Wait-OrderStatus $order.id 'paid')" -ForegroundColor Green
    }
    Show-Overview
    Wait-Key
}

function Invoke-UpdateScenario([string]$Name) {
    Write-Title "UPDATE: rebuild and redeploy only $Name"
    $all = @($Services.Keys) + @($Services.Keys | ForEach-Object { Get-DbName $_ }) + @("rabbitmq", "api-gateway")
    $startedBefore = @{}
    foreach ($c in $all) { $startedBefore[$c] = (Get-ContainerState $c).StartedAt }

    Invoke-Compose @("up", "-d", "--build", "--no-deps", "--force-recreate", $Name)
    Wait-Healthy $Name

    Write-Host ""
    Write-Host "  Which containers were restarted by the deployment:"
    foreach ($c in $all) {
        $changed = (Get-ContainerState $c).StartedAt -ne $startedBefore[$c]
        if ($changed) { Write-Host ("    {0,-22} RESTARTED (new version)" -f $c) -ForegroundColor Yellow }
        else { Write-Host ("    {0,-22} untouched" -f $c) -ForegroundColor Green }
    }
    Show-BusinessChecks
    Wait-Key
}

# ================================================================== main
Write-Title "ShopHub: 6 microservices, each with its own container and its own database"
if ((Invoke-Api GET "$Gateway/health").Status -ne 200) {
    throw "The stack is not running. Run 'docker compose up -d --build' in the lab2 folder first."
}
foreach ($name in $Services.Keys) { Wait-Healthy $name }
Show-Overview

$script:Email = "demo-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "@example.com"
$script:Password = "Secret123!"
$r = Invoke-Api POST "$Gateway/api/auth/register" @{ email = $script:Email; password = $script:Password; full_name = "Demo User" }
if ($r.Status -ne 201) { throw "registration failed: $($r.Status) $($r.Error)" }
$script:Token = (Invoke-Api POST "$Gateway/api/auth/login" @{ email = $script:Email; password = $script:Password }).Data.access_token
$product = (Invoke-Api GET "$Gateway/api/products?limit=100").Data.items | Where-Object { $_.stock -gt 5 } | Select-Object -First 1
$script:ProductId = $product.id
Write-Host ""
Write-Host "  Demo customer: $script:Email (logged in; the JWT is checked by every service itself)"
Show-BusinessChecks
Wait-Key

$every = if ($Service -eq "all") { @($Services.Keys) } else { @($Service) }
$one = if ($Service -eq "all") { "payment-service" } else { $Service }

if ($Scenario -in @("all", "stop"))     { foreach ($s in $every) { Invoke-StopScenario $s } }
if ($Scenario -in @("all", "crash"))    { foreach ($s in $every) { Invoke-CrashScenario $s } }
if ($Scenario -in @("all", "database")) { Invoke-DatabaseScenario $one }
if ($Scenario -in @("all", "update"))   { Invoke-UpdateScenario $one }

Write-Title "Result: every failure stayed inside one microservice, the shop kept working"
Show-Overview
Show-BusinessChecks
