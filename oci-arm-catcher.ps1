#requires -Version 5.1
<#
.SYNOPSIS
    oci-arm-catcher — grabs free Oracle Cloud ARM capacity (VM.Standard.A1.Flex)
    and launches an instance the moment capacity appears. Windows port.

.DESCRIPTION
    Calls `oci compute instance launch` in a loop. On capacity-related errors
    ("Out of host capacity", InternalError, LimitExceeded, TooManyRequests,
    timeouts) it waits RetryInterval seconds and retries, optionally rotating
    across several Availability Domains. On success it parses the instance OCID
    and shows a Windows toast notification.

.PARAMETER ConfigFile
    Path to the .env-style config file. Defaults to .env next to this script.

.EXAMPLE
    Copy-Item .env.example .env   # then edit .env
    .\oci-arm-catcher.ps1

.NOTES
    Prerequisites:
      - OCI CLI installed and on PATH
      - oci setup config  (creates %USERPROFILE%\.oci\config)
    See README.md for how to obtain each OCID.
#>

[CmdletBinding()]
param(
    [string]$ConfigFile
)

# ─── LOCATE & LOAD CONFIG ─────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigFile) {
    $ConfigFile = if ($env:OCI_ARM_CATCHER_ENV) { $env:OCI_ARM_CATCHER_ENV } else { Join-Path $ScriptDir '.env' }
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Error: Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Copy .env.example to .env and fill in your values, or pass -ConfigFile <path>." -ForegroundColor Red
    exit 1
}

# Parse a simple KEY="value" / KEY=value .env file into a hashtable.
$cfg = @{}
foreach ($line in Get-Content -LiteralPath $ConfigFile) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    if ($t -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        $key = $matches[1]
        $val = $matches[2].Trim()
        if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        # Expand $HOME / ${HOME} / %USERPROFILE% so key paths work cross-shell.
        $val = $val -replace '\$\{?HOME\}?', $HOME.Replace('\','\\')
        $val = $val -replace '%USERPROFILE%', $HOME.Replace('\','\\')
        $cfg[$key] = $val
    }
}

# ─── VALIDATE CONFIG ──────────────────────────────────────────────────────────

# Single AvailabilityDomain or comma-separated AvailabilityDomains (rotation).
$ads = @()
if ($cfg.ContainsKey('AVAILABILITY_DOMAINS') -and $cfg['AVAILABILITY_DOMAINS']) {
    $ads = $cfg['AVAILABILITY_DOMAINS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} elseif ($cfg.ContainsKey('AVAILABILITY_DOMAIN') -and $cfg['AVAILABILITY_DOMAIN']) {
    $ads = @($cfg['AVAILABILITY_DOMAIN'])
}

$required = 'COMPARTMENT_ID','IMAGE_ID','SUBNET_ID','SSH_KEY_FILE','OCPUS','MEMORY_GB','DISPLAY_NAME'
$missing = $false
foreach ($v in $required) {
    if (-not $cfg.ContainsKey($v) -or -not $cfg[$v]) {
        Write-Host "Error: required config variable is empty: $v" -ForegroundColor Red
        $missing = $true
    }
}
if ($ads.Count -eq 0) {
    Write-Host "Error: set AVAILABILITY_DOMAIN or AVAILABILITY_DOMAINS in your config." -ForegroundColor Red
    $missing = $true
}
if ($cfg['SSH_KEY_FILE'] -and -not (Test-Path $cfg['SSH_KEY_FILE'])) {
    Write-Host "Error: SSH public key not found: $($cfg['SSH_KEY_FILE'])" -ForegroundColor Red
    $missing = $true
}
if (-not (Get-Command oci -ErrorAction SilentlyContinue)) {
    Write-Host "Error: the 'oci' CLI is not installed or not on PATH." -ForegroundColor Red
    Write-Host "Install it: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm" -ForegroundColor Red
    $missing = $true
}
if ($missing) { exit 1 }

$retryInterval = if ($cfg.ContainsKey('RETRY_INTERVAL') -and $cfg['RETRY_INTERVAL']) { [int]$cfg['RETRY_INTERVAL'] } else { 300 }

# ─── HELPERS ──────────────────────────────────────────────────────────────────

function Send-Notification {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
    try {
        # Windows toast via BurntToast if available, else a balloon tip.
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text 'oci-arm-catcher', $Message | Out-Null
        } else {
            Add-Type -AssemblyName System.Windows.Forms
            $balloon = New-Object System.Windows.Forms.NotifyIcon
            $balloon.Icon = [System.Drawing.SystemIcons]::Information
            $balloon.BalloonTipTitle = 'oci-arm-catcher'
            $balloon.BalloonTipText = $Message
            $balloon.Visible = $true
            $balloon.ShowBalloonTip(8000)
        }
    } catch {
        # Notification is best-effort; never let it crash the loop.
    }
}

function Get-OciError {
    param([string]$Output)
    $code = 'Error'; $msg = ''
    $m = [regex]::Match($Output, '\{.*\}', 'Singleline')
    if ($m.Success) {
        try {
            $d = $m.Value | ConvertFrom-Json
            if ($d.code)    { $code = $d.code }
            elseif ($d.status) { $code = $d.status }
            if ($d.message) { $msg = $d.message }
        } catch { }
    }
    if (-not $msg) {
        $line = ($Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('{') -and $_.Contains(':') } | Select-Object -First 1)
        $msg = if ($line) { $line } else { ($Output.Trim() -split "`n")[-1] }
    }
    [pscustomobject]@{ Code = $code; Message = if ($msg) { $msg } else { 'no message' } }
}

# ─── MAIN LOOP ────────────────────────────────────────────────────────────────

Write-Host "=== oci-arm-catcher started at $(Get-Date) ==="
Write-Host "Shape: VM.Standard.A1.Flex  |  OCPU: $($cfg['OCPUS'])  |  RAM: $($cfg['MEMORY_GB'])GB"
if ($ads.Count -gt 1) {
    Write-Host "Availability Domains (rotating): $($ads -join ', ')"
} else {
    Write-Host "Availability Domain: $($ads[0])"
}
Write-Host "Retry interval: $([math]::Floor($retryInterval / 60)) min`n"

$retryable = 'out of capacity|out of host capacity|InternalError|LimitExceeded|TooManyRequests|timed out|RequestException|ServiceUnavailable|Service Unavailable'
$shapeConfig = "{`"ocpus`": $($cfg['OCPUS']), `"memoryInGBs`": $($cfg['MEMORY_GB'])}"

$attempt = 0
$adIndex = 0

while ($true) {
    $attempt++
    $currentAd = $ads[$adIndex]
    if ($ads.Count -gt 1) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt #$attempt  (AD: $currentAd)"
    } else {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt #$attempt"
    }

    $output = & oci compute instance launch `
        --compartment-id      $cfg['COMPARTMENT_ID'] `
        --availability-domain $currentAd `
        --display-name        $cfg['DISPLAY_NAME'] `
        --shape               'VM.Standard.A1.Flex' `
        --shape-config        $shapeConfig `
        --image-id            $cfg['IMAGE_ID'] `
        --subnet-id           $cfg['SUBNET_ID'] `
        --ssh-authorized-keys-file $cfg['SSH_KEY_FILE'] `
        --assign-public-ip    true `
        --connection-timeout  60 `
        --read-timeout        120 2>&1 | Out-String
    $status = $LASTEXITCODE

    if ($status -eq 0) {
        $instanceId = 'unknown'
        try { $instanceId = ($output | ConvertFrom-Json).data.id } catch { }
        Send-Notification "SUCCESS! Instance created: $instanceId"
        Write-Host $output
        exit 0
    }

    $err = Get-OciError $output
    Write-Host "  -> $($err.Code): $($err.Message)"

    if ($output -match $retryable) {
        if ($ads.Count -gt 1) { $adIndex = ($adIndex + 1) % $ads.Count }
        for ($rem = $retryInterval; $rem -gt 0; $rem--) {
            Write-Host -NoNewline ("`r  ⏳ {0:00}:{1:00} until next attempt" -f [math]::Floor($rem / 60), ($rem % 60))
            Start-Sleep -Seconds 1
        }
        Write-Host "`r$((' ' * 40))`r" -NoNewline
    } else {
        Write-Host "  -> Unexpected error, stopping." -ForegroundColor Red
        Write-Host $output
        Send-Notification 'Unexpected OCI error — check the terminal.'
        exit 1
    }
}
