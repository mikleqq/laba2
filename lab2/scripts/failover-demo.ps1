<#
.SYNOPSIS
    Terminal version of the fault-isolation demo (the main demo is the web UI: frontend\index.html).

.DESCRIPTION
    6 microservices = 6 containers. For each scenario the script breaks ONE service and then
    calls one business endpoint of every service: only the broken one fails, the other five answer.
      stop    - docker compose stop <service>, then start it again
      crash   - POST /chaos/crash: the process dies, Docker restarts the container by itself
      update  - rebuild and redeploy ONE service; no other container is restarted
      all     - everything above

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\failover-demo.ps1 -Scenario crash -Service payment-service -Pause
#>
param(
    [ValidateSet("all", "overview", "stop", "crash", "update")]
    [string]$Scenario = "all",
    [ValidateSet("all", "auth-service", "user-service", "product-service", "order-service", "payment-service", "notification-service")]
    [string]$Service = "all",
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
function Url([string]$Name, [string]$Path) { return "http://localhost:$($Services[$Name])$Path" }

# ---------------------------------------------------------------- output
function Write-Title([string]$text) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray
}
function Write-Cmd([string]$text) { Write-Host ""; Write-Host "  >>> $text" -ForegroundColor Yellow }
function Wait-Key { if ($Pause) { [void](Read-Host "  ...press Enter to continue") } }

# ---------------------------------------------------------------- docker
function Invoke-Docker {
    $ErrorActionPreference = "Continue"   # docker writes progress to stderr
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

# ---------------------------------------------------------------- http
function Invoke-Api([string]$Method, [string]$Url, $Body = $null, [hashtable]$Headers = @{}) {
    $params = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 10 }
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
        if ($null -eq $resp) { return [pscustomobject]@{ Status = 0; Data = $null; Error = "service does not respond" } }
        $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
        try { $msg = ($msg | ConvertFrom-Json).error.message } catch { }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Data = $null; Error = $msg }
    }
}
function Auth { return @{ Authorization = "Bearer $script:Token" } }

# ---------------------------------------------------------------- views
function Show-Overview {
    Write-Host ""
    Write-Host ("  {0,-22} {1,-22} {2}" -f "MICROSERVICE", "CONTAINER", "API")
    foreach ($name in $Services.Keys) {
        $c = Get-ContainerState $name
        $up = (Invoke-Api GET (Url $name "/health")).Status -eq 200
        $cText = if ($c.Status -eq "running") { "running ($($c.Health))" } else { $c.Status }
        $color = if ($up) { "Green" } else { "Red" }
        Write-Host ("  {0,-22} {1,-22} {2}" -f $name, $cText, $(if ($up) { "UP" } else { "DOWN" })) -ForegroundColor $color
    }
}

$Checks = [ordered]@{
    "auth-service"         = @("POST", "/auth/login", "POST /auth/login")
    "user-service"         = @("GET", "/users/me", "GET  /users/me")
    "product-service"      = @("GET", "/products?limit=3", "GET  /products")
    "order-service"        = @("GET", "/orders", "GET  /orders")
    "payment-service"      = @("GET", "/payments", "GET  /payments")
    "notification-service" = @("GET", "/notifications", "GET  /notifications")
}
function Show-BusinessChecks {
    Write-Host ""
    Write-Host "  The shop: one business request to every microservice:"
    foreach ($name in $Checks.Keys) {
        $method, $path, $label = $Checks[$name]
        $body = if ($name -eq "auth-service") { @{ email = $script:Email; password = $script:Password } } else { $null }
        $r = Invoke-Api $method (Url $name $path) $body (Auth)
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            Write-Host ("    {0,-22} {1,-24} -> {2}  OK" -f $name, $label, $r.Status) -ForegroundColor Green
        } else {
            Write-Host ("    {0,-22} {1,-24} -> {2}  FAIL: {3}" -f $name, $label, $r.Status, $r.Error) -ForegroundColor Red
        }
    }
}
function New-Order {
    $r = Invoke-Api POST (Url "order-service" "/orders") @{ items = @(@{ product_id = $script:ProductId; quantity = 1 }) } (Auth)
    if ($r.Status -ne 201) { throw "order creation failed: $($r.Status) $($r.Error)" }
    return $r.Data
}
function Get-OrderStatus([int]$Id) { return (Invoke-Api GET (Url "order-service" "/orders/$Id") $null (Auth)).Data.status }
function Wait-OrderStatus([int]$Id, [string]$Expected) {
    for ($i = 0; $i -lt 30; $i++) {
        $s = Get-OrderStatus $Id
        if ($s -eq $Expected) { return $s }
        Start-Sleep -Seconds 1
    }
    return Get-OrderStatus $Id
}

# ---------------------------------------------------------------- scenarios
function Invoke-StopScenario([string]$Name) {
    Write-Title "STOP: container $Name is switched off"
    Invoke-Compose @("stop", $Name)
    Show-Overview
    Show-BusinessChecks
    $order = $null
    if ($Name -eq "payment-service") {
        $order = New-Order
        Write-Host ""
        Write-Host "    order #$($order.id) accepted while payment-service is off: $($order.status) (event waits in bus.events)"
    }
    Wait-Key
    Invoke-Compose @("start", $Name)
    Wait-Healthy $Name
    Write-Host "    $Name is healthy again" -ForegroundColor Green
    if ($order) { Write-Host "    order #$($order.id) status now = $(Wait-OrderStatus $order.id 'paid')" -ForegroundColor Green }
    Wait-Key
}

function Invoke-CrashScenario([string]$Name) {
    Write-Title "CRASH: the process of $Name dies (exit code 1)"
    $before = (Get-ContainerState $Name).Restarts
    Write-Cmd "POST $(Url $Name '/chaos/crash')"
    $r = Invoke-Api POST (Url $Name "/chaos/crash") $null @{ "X-Internal-Token" = $InternalToken }
    if ($r.Status -ne 200) { throw "crash endpoint failed: $($r.Status) $($r.Error)" }
    Start-Sleep -Milliseconds 400
    Show-BusinessChecks
    Wait-Key
    Write-Host ""
    Write-Host "  Nobody touches anything: Docker restarts the container (restart: unless-stopped)" -ForegroundColor Cyan
    for ($i = 0; $i -lt 30 -and (Get-ContainerState $Name).Restarts -le $before; $i++) { Start-Sleep -Seconds 1 }
    Wait-Healthy $Name
    Write-Host "    restart count of ${Name}: $before -> $((Get-ContainerState $Name).Restarts), healthy again" -ForegroundColor Green
    Wait-Key
}

function Invoke-UpdateScenario([string]$Name) {
    Write-Title "UPDATE: rebuild and redeploy only $Name"
    $before = @{}
    foreach ($c in $Services.Keys) { $before[$c] = (Get-ContainerState $c).StartedAt }
    Invoke-Compose @("up", "-d", "--build", "--no-deps", "--force-recreate", $Name)
    Wait-Healthy $Name
    Write-Host ""
    Write-Host "  Which containers were restarted:"
    foreach ($c in $Services.Keys) {
        if ((Get-ContainerState $c).StartedAt -ne $before[$c]) { Write-Host ("    {0,-22} RESTARTED (new version)" -f $c) -ForegroundColor Yellow }
        else { Write-Host ("    {0,-22} untouched" -f $c) -ForegroundColor Green }
    }
    Show-BusinessChecks
    Wait-Key
}

# ---------------------------------------------------------------- main
Write-Title "ShopHub: 6 microservices = 6 containers, 1 PostgreSQL database"
foreach ($name in $Services.Keys) { Wait-Healthy $name 60 }
Show-Overview

$script:Email = "demo-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "@example.com"
$script:Password = "Secret123!"
$r = Invoke-Api POST (Url "auth-service" "/auth/register") @{ email = $script:Email; password = $script:Password; full_name = "Demo" }
if ($r.Status -ne 201) { throw "registration failed: $($r.Status) $($r.Error)" }
$script:Token = (Invoke-Api POST (Url "auth-service" "/auth/login") @{ email = $script:Email; password = $script:Password }).Data.access_token
$script:ProductId = ((Invoke-Api GET (Url "product-service" "/products?limit=100")).Data.items | Where-Object { $_.stock -gt 5 } | Select-Object -First 1).id
Write-Host ""
Write-Host "  Demo customer $script:Email is logged in (every service checks the JWT itself)"
Show-BusinessChecks
Wait-Key

$every = if ($Service -eq "all") { @($Services.Keys) } else { @($Service) }
$one = if ($Service -eq "all") { "payment-service" } else { $Service }
if ($Scenario -in @("all", "stop"))   { foreach ($s in $every) { Invoke-StopScenario $s } }
if ($Scenario -in @("all", "crash"))  { foreach ($s in $every) { Invoke-CrashScenario $s } }
if ($Scenario -in @("all", "update")) { Invoke-UpdateScenario $one }

Write-Title "Result: every failure stayed inside one microservice"
Show-Overview
Show-BusinessChecks
