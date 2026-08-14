#requires -Version 5.1
<#
.SYNOPSIS
    NAT Tunnel Manager — ngrok-like access to your intranet via Cloudflare Tunnel.

.DESCRIPTION
    Wraps `cloudflared` so you can expose local / intranet services through a
    custom domain (hostname) that you own on Cloudflare. Everything is managed
    from a single script: install, login, create the tunnel + DNS route, and run it.

    COMMANDS
      install   Install cloudflared (Windows via winget).
      update    Update cloudflared to the latest version.
      login     Authenticate cloudflared to your Cloudflare account (opens browser).
      setup     Create a named tunnel + DNS route + generate cloudflared config.yml.
      quick     Instant "ngrok-style" tunnel with a random trycloudflare.com URL.
      start     Start the configured tunnel in the background.
      stop      Stop the running tunnel.
      restart   Stop then start the tunnel.
      status    Show running status + your public URLs.
      list      List services configured in config.json.
      delete    Delete a service from config (and regenerate config.yml).
      cleanup   Delete the tunnel and its DNS routes.
      help      Show this help.

.EXAMPLE
    .\nat-tunnel.ps1 install
    .\nat-tunnel.ps1 login
    .\nat-tunnel.ps1 setup -ServiceName web -Hostname app.example.com -Url http://localhost:3000
    .\nat-tunnel.ps1 start
    .\nat-tunnel.ps1 status
    .\nat-tunnel.ps1 stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'login', 'setup', 'quick', 'start', 'stop', 'restart', 'status', 'list', 'delete', 'cleanup', 'help')]
    [string]$Command = 'help',

    [string]$ServiceName = 'default',
    [string]$Hostname,
    [string]$Url = 'http://localhost:8080',
    [string]$TunnelName = 'nat-tunnel',
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Paths & state
# ------------------------------------------------------------------
# NOTE: $PSScriptRoot is NOT available while parameter defaults are being
# bound (esp. with [CmdletBinding()]), so we resolve the script's folder
# here in the body via $MyInvocation instead of in the param() block.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir 'config.json'
}

$HomeCloudflared = Join-Path $HOME '.cloudflared'
$CertFile        = Join-Path $HomeCloudflared 'cert.pem'
$PidFile         = Join-Path $ScriptDir '.tunnel.pid'
$LogDir          = Join-Path $ScriptDir 'logs'
$ConfigDir       = Join-Path $ScriptDir 'cloudflared'
$GeneratedYaml   = Join-Path $ConfigDir 'config.yml'

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" }
function Write-Ok   { param([string]$Message) Write-Host "    OK: $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    WARN: $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    ERROR: $Message" -ForegroundColor Red }

function Assert-Cloudflared {
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Err "cloudflared was not found in PATH."
        Write-Info "Run: .\nat-tunnel.ps1 install"
        throw 'cloudflared missing'
    }
    return $cmd.Source
}

function Invoke-Cloudflared {
    # Runs cloudflared. cloudflared writes harmless chatter (e.g. "version is
    # outdated" warnings) to stderr, which PowerShell 5.1 with
    # $ErrorActionPreference='Stop' turns into a terminating NativeCommandError.
    # So we temporarily lower EAP and divert stderr; on a real failure we show
    # the meaningful stderr lines.
    param([string[]]$Arguments)
    $exe = Assert-Cloudflared
    Write-Info "> cloudflared $($Arguments -join ' ')"
    $prev = $ErrorActionPreference
    $errFile = Join-Path $env:TEMP "nat-cf-err-$PID.log"
    try {
        $ErrorActionPreference = 'Continue'
        & $exe @Arguments 2>$errFile
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        $detail = @(Get-Content $errFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -notmatch 'outdated|upgrade|version' } |
            Select-Object -Last 5)
        $msg = "cloudflared exited with code $LASTEXITCODE"
        if ($detail.Count -gt 0) { $msg += "`n" + ($detail -join "`n") }
        Remove-Item $errFile -ErrorAction SilentlyContinue
        throw $msg
    }
    Remove-Item $errFile -ErrorAction SilentlyContinue
}

function Get-LocalConfig {
    if (-not (Test-Path $ConfigPath)) {
        Write-Step "No config.json found - creating a default one at $ConfigPath"
        $default = [ordered]@{
            tunnelName = $TunnelName
            services   = @(
                [ordered]@{ name = 'default'; hostname = ''; url = 'http://localhost:8080' }
            )
        }
        $default | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
    }
    return Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Save-LocalConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Get-TunnelId {
    param([string]$Name)
    $exe = Assert-Cloudflared
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $list = & $exe tunnel list 2>$null | Out-String
    } finally {
        $ErrorActionPreference = $prev
    }
    $pattern = "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+$([regex]::Escape($Name))\s"
    $m = [regex]::Match($list, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Show-Urls {
    param($Config)
    Write-Host ""
    Write-Host "  Your public URLs:" -ForegroundColor Green
    foreach ($s in $Config.services) {
        if ($s.hostname) { Write-Host "    https://$($s.hostname)  ->  $($s.url)" }
    }
    Write-Host ""
}

function Write-CloudflaredConfig {
    param($Config)
    $tunnel   = $Config.tunnelName
    $tunnelId = Get-TunnelId -Name $tunnel
    if (-not $tunnelId) { throw "Tunnel '$tunnel' not found. Run 'setup' first." }
    $credFile = (Join-Path $HomeCloudflared "$tunnelId.json") -replace '\\', '/'
    if (-not (Test-Path $credFile)) { throw "Credentials file not found: $credFile" }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("tunnel: $tunnel")
    $lines.Add("credentials-file: $credFile")
    $lines.Add("")
    $lines.Add("ingress:")
    foreach ($s in $Config.services) {
        if (-not $s.hostname) { continue }
        $lines.Add("  - hostname: $($s.hostname)")
        $lines.Add("    service: $($s.url)")
    }
    $lines.Add("  - service: http_status:404")
    $lines.Add("")

    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Set-Content -Path $GeneratedYaml -Value $lines -Encoding UTF8
    Write-Ok "Wrote $GeneratedYaml"
}

# ------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------
function Install-Cloudflared {
    if (Get-Command cloudflared -ErrorAction SilentlyContinue) {
        Write-Ok "cloudflared is already installed: $((Get-Command cloudflared).Source)"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Err "winget not found."
        Write-Info "Download cloudflared manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        return
    }
    Write-Step "Installing cloudflared via winget..."
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        winget install --id Cloudflare.cloudflared -e --accept-package-agreements --accept-source-agreements
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "cloudflared installed. Restart your terminal if PATH was updated."
    } else {
        Write-Err "winget failed (code $LASTEXITCODE). Install manually from the link above."
    }
}

function Update-Cloudflared {
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-Err "cloudflared is not installed yet. Run: .\nat-tunnel.ps1 install"
        return
    }
    Write-Step "Updating cloudflared..."
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        cloudflared update 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
    $ok = $LASTEXITCODE -eq 0
    if (-not $ok) {
        Write-Warn "Self-update not supported for this install - falling back to winget..."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            try {
                $ErrorActionPreference = 'Continue'
                winget upgrade --id Cloudflare.cloudflared -e --accept-package-agreements --accept-source-agreements
            } finally {
                $ErrorActionPreference = $prev
            }
            $ok = $LASTEXITCODE -eq 0
        }
    }
    if ($ok) {
        $v = & (Get-Command cloudflared).Source --version 2>$null
        Write-Ok "cloudflared is up to date: $v"
    } else {
        Write-Err "Update failed. Download the latest manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    }
}

function Login-Cloudflare {
    $exe = Assert-Cloudflared
    if (Test-Path $CertFile) {
        Write-Ok "Already logged in ($CertFile)"
        return
    }
    Write-Step "Opening your browser to authorize cloudflared..."
    Write-Info "Pick the domain you own in the Cloudflare dashboard and click 'Authorize'."
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $exe tunnel login 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -eq 0 -and (Test-Path $CertFile)) {
        Write-Ok "Login successful. Certificate saved to $CertFile"
    }
}

function Setup-Tunnel {
    param([string]$Service, [string]$Hostname, [string]$Target)

    Assert-Cloudflared | Out-Null
    if (-not (Test-Path $CertFile)) {
        Write-Err "You are not logged in yet."
        Write-Info "Run: .\nat-tunnel.ps1 login"
        return
    }
    if (-not $Hostname) {
        Write-Err "Please provide -Hostname (e.g. app.example.com)"
        Write-Info "Example: .\nat-tunnel.ps1 setup -ServiceName web -Hostname app.example.com -Url http://localhost:3000"
        return
    }

    $config = Get-LocalConfig
    $tunnel = $config.tunnelName

    # 1. Create the named tunnel if it does not exist
    $tunnelId = Get-TunnelId -Name $tunnel
    if (-not $tunnelId) {
        Write-Step "Creating named tunnel '$tunnel'..."
        Invoke-Cloudflared @('tunnel', 'create', $tunnel)
    } else {
        Write-Ok "Tunnel '$tunnel' already exists ($tunnelId)"
    }

    # 2. Point DNS at the tunnel (creates the CNAME route on your domain)
    Write-Step "Routing DNS: $Hostname -> tunnel '$tunnel'"
    Invoke-Cloudflared @('tunnel', 'route', 'dns', $tunnel, $Hostname)

    # 3. Store the service in config.json
    $existing = @($config.services | Where-Object { $_.name -eq $Service })
    if ($existing.Count -gt 0) {
        $existing[0].hostname = $Hostname
        $existing[0].url      = $Target
    } else {
        $config.services += [pscustomobject]@{ name = $Service; hostname = $Hostname; url = $Target }
    }
    Save-LocalConfig $config

    # 4. Generate the cloudflared config.yml
    Write-CloudflaredConfig -Config $config

    Write-Step "Done! Start the tunnel with:  .\nat-tunnel.ps1 start"
}

function Start-QuickTunnel {
    Assert-Cloudflared | Out-Null
    Write-Step "Starting quick tunnel to $Url (random trycloudflare.com URL, no login needed)"
    Write-Info "Press Ctrl+C to stop."
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & (Get-Command cloudflared).Source tunnel --url $Url 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Start-Tunnel {
    $config = Get-LocalConfig
    Write-CloudflaredConfig -Config $config

    $running = Get-RunningPid
    if ($running) {
        Write-Warn "Tunnel is already running (PID $running)."
        return
    }

    $exe = Assert-Cloudflared
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stdout = Join-Path $LogDir 'cloudflared.out.log'
    $stderr = Join-Path $LogDir 'cloudflared.err.log'

    $args = @('tunnel', '--config', $GeneratedYaml, 'run', $config.tunnelName)
    $proc = Start-Process -FilePath $exe -ArgumentList $args `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -WindowStyle Hidden -PassThru

    $proc.Id | Set-Content $PidFile
    Write-Ok "Tunnel started with PID $($proc.Id)"
    Write-Info "Logs: $stdout  /  $stderr"

    Start-Sleep -Seconds 4
    if ($proc.HasExited) {
        Write-Err "cloudflared exited early (code $($proc.ExitCode)). Check the log:"
        Get-Content $stderr -ErrorAction SilentlyContinue | Select-Object -Last 15
    } else {
        Show-Urls -Config $config
    }
}

function Get-RunningPid {
    if (-not (Test-Path $PidFile)) { return $null }
    $val = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $val) { return $null }
    $proc = Get-Process -Id $val -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.HasExited) { return [int]$val }
    return $null
}

function Stop-Tunnel {
    $val = Get-RunningPid
    if (-not $val) {
        Write-Warn "No running tunnel found."
        return
    }
    Stop-Process -Id $val -Force -ErrorAction SilentlyContinue
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Write-Ok "Tunnel stopped (PID $val)."
}

function Get-TunnelStatus {
    $val = Get-RunningPid
    if ($val) { Write-Ok "Tunnel is RUNNING (PID $val)" }
    else      { Write-Warn "Tunnel is NOT running." }

    $config = Get-LocalConfig
    Show-Urls -Config $config

    Write-Step "Cloudflare named tunnels:"
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        cloudflared tunnel list 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }

    Write-Step "Configured local services:"
    foreach ($s in $config.services) {
        Write-Info "  [$($s.name)] $($s.url)  =>  https://$($s.hostname)"
    }
}

function Remove-Service {
    param([string]$Service)
    $config = Get-LocalConfig
    $svc = @($config.services | Where-Object { $_.name -eq $Service })
    if ($svc.Count -eq 0) {
        Write-Err "No service named '$Service' in config.json."
        return
    }
    $config.services = @($config.services | Where-Object { $_.name -ne $Service })
    Save-LocalConfig $config
    Write-CloudflaredConfig -Config $config
    Write-Ok "Removed service '$Service' from config."
    Write-Info "Note: the DNS CNAME record still exists in Cloudflare - delete it from the dashboard if you no longer need it."
}

function Remove-All {
    Stop-Tunnel
    $config = Get-LocalConfig
    $tunnel = $config.tunnelName

    Write-Step "Deleting DNS routes & tunnel '$tunnel'..."
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        cloudflared tunnel cleanup $tunnel 2>$null | Out-Null
        cloudflared tunnel delete $tunnel --force 2>$null
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($rc -eq 0) { Write-Ok "Tunnel '$tunnel' deleted." }
    else {
        Write-Err "Could not delete tunnel automatically (code $rc)."
        Write-Info "Delete the CNAME records for your hostnames in the Cloudflare dashboard, then run:"
        Write-Info "  cloudflared tunnel delete $tunnel"
    }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------
switch ($Command) {
    'install' { Install-Cloudflared }
    'update'  { Update-Cloudflared }
    'login'   { Login-Cloudflare }
    'setup'   { Setup-Tunnel -Service $ServiceName -Hostname $Hostname -Target $Url }
    'quick'   { Start-QuickTunnel }
    'start'   { Start-Tunnel }
    'stop'    { Stop-Tunnel }
    'restart' { Stop-Tunnel; Start-Tunnel }
    'status'  { Get-TunnelStatus }
    'list'    { Get-LocalConfig | Select-Object -ExpandProperty services | Format-Table -AutoSize }
    'delete'  { Remove-Service -Service $ServiceName }
    'cleanup' { Remove-All }
    'help'    { Get-Help $MyInvocation.MyCommand.Path -Full }
}
