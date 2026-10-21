# Shares the WeOwnFeed web UI through localtunnel.
# Usage (in the project folder):  powershell -ExecutionPolicy Bypass -File .\share_tunnel.ps1
# To rebuild first:               powershell -ExecutionPolicy Bypass -File .\share_tunnel.ps1 -Build
# Visitors' browsers cannot reach "localhost", so the build uses the server's
# tunnel address (change it with -ApiUrl).

param(
    [int]$Port = 8080,
    [string]$Subdomain = "wof-rss-ui",
    [string]$ApiUrl = "https://agentic-news-backend.loca.lt",
    [switch]$Build
)

$root = $PSScriptRoot
$web = Join-Path $root "build\web"
$serverLog = Join-Path $env:TEMP "wof_http_server.log"

if ($Build -or -not (Test-Path (Join-Path $web "index.html"))) {
    Write-Host "Flutter web derleniyor..." -ForegroundColor Cyan
    Push-Location $root
    flutter build web --release --dart-define=API_BASE_URL=$ApiUrl
    $ok = $?
    Pop-Location
    if (-not $ok) { Write-Host "Build failed." -ForegroundColor Red; exit 1 }
}

function Start-Server {
    Write-Host "Starting the local server: http://127.0.0.1:$Port (log: $serverLog)" -ForegroundColor Cyan
    Start-Process python -ArgumentList "-m", "http.server", "$Port", "--bind", "127.0.0.1" `
        -WorkingDirectory $web -NoNewWindow -PassThru `
        -RedirectStandardError $serverLog -RedirectStandardOutput "$serverLog.out"
}

# If localtunnel hands out a random address because the old name is not free
# yet (the shared link would not work), the tunnel is closed and retried after 30 s.
function Start-Tunnel {
    $wanted = "https://$Subdomain.loca.lt"
    $log = Join-Path $env:TEMP "wof_ui_tunnel_$Port.log"
    while ($true) {
        Write-Host "Opening tunnel: $wanted" -ForegroundColor Cyan
        Remove-Item $log -ErrorAction SilentlyContinue
        $p = Start-Process npx.cmd -ArgumentList "-y", "localtunnel", "--port", "$Port", "--subdomain", $Subdomain `
            -NoNewWindow -PassThru -RedirectStandardOutput $log
        $url = $null
        for ($i = 0; $i -lt 45 -and -not $url -and -not $p.HasExited; $i++) {
            Start-Sleep -Seconds 1
            $m = Select-String -Path $log -Pattern "your url is: (\S+)" -ErrorAction SilentlyContinue
            if ($m) { $url = $m.Matches[0].Groups[1].Value }
        }
        if ($url -eq $wanted) {
            Write-Host "Tunnel ready: $url" -ForegroundColor Green
            return $p
        }
        Write-Host "Could not get the requested address ($url); retrying in 30 s..." -ForegroundColor Yellow
        if (-not $p.HasExited) { taskkill /PID $p.Id /T /F | Out-Null }
        Start-Sleep -Seconds 30
    }
}

try {
    $password = (Invoke-RestMethod -Uri "https://loca.lt/mytunnelpassword" -TimeoutSec 15)
    Write-Host "Tunnel password (visitors enter it): $password" -ForegroundColor Yellow
} catch {
    Write-Host "Could not fetch the password; see https://loca.lt/mytunnelpassword." -ForegroundColor Yellow
}

$server = Start-Server
Start-Sleep -Seconds 2
$tunnel = Start-Tunnel
Write-Host "Press Ctrl+C to stop. The server or tunnel reopens automatically if it closes." -ForegroundColor Cyan

try {
    while ($true) {
        Start-Sleep -Seconds 5
        if ($server.HasExited) {
            Write-Host "Local server stopped (code $($server.ExitCode)), restarting..." -ForegroundColor Red
            $server = Start-Server
        }
        if ($tunnel.HasExited) {
            # Wait a bit so the old subdomain is freed on the server;
            # otherwise localtunnel hands out a random address.
            Write-Host "Tunnel closed, reopening in 15 s..." -ForegroundColor Red
            Start-Sleep -Seconds 15
            $tunnel = Start-Tunnel
        }
    }
} finally {
    foreach ($p in @($server, $tunnel)) {
        if ($p -and -not $p.HasExited) { taskkill /PID $p.Id /T /F | Out-Null }
    }
    Write-Host "Server and tunnel stopped." -ForegroundColor Cyan
}
