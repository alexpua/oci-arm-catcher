#requires -Version 5.1
<#
.SYNOPSIS
    oci-arm-catcher - grabs free Oracle Cloud ARM capacity (VM.Standard.A1.Flex)
    and launches an instance the moment capacity appears. Windows port.

.DESCRIPTION
    Calls `oci compute instance launch` in a loop. On transient errors it waits
    RetryInterval seconds and retries, optionally rotating across several
    Availability Domains. On success it parses the instance OCID and shows a
    Windows toast notification.

    IMPORTANT DESIGN NOTE (fixes a real bug that hit this script in production):

    The previous version used an *allow-list* of "known retryable" error
    substrings, and treated anything that didn't match as fatal ("Unexpected
    error, stopping."). That's backwards for a tool whose whole job is to sit
    and wait for transient capacity errors: OCI/the CLI doesn't always phrase a
    transient/capacity error the same way (different `code`, a raw traceback
    instead of clean JSON, an unfamiliar 5xx, a network blip, etc.), so the
    allow-list would eventually miss one and the script would silently quit
    after hundreds/thousands of otherwise-identical attempts - which is
    exactly what was happening, at a different attempt number each time,
    whenever OCI worded a capacity/rate-limit error slightly differently than
    the last one.

    Fix: flip it to a *deny-list* of genuinely fatal, non-retryable errors
    (bad config, bad auth, invalid resource ids - things that will NEVER be
    fixed by waiting and retrying). Everything else is treated as retryable
    by default. Worst case with this approach is a wasted retry; worst case
    with the old approach was the hunt silently dying for hours without you
    knowing.

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

# --- LOCATE & LOAD CONFIG -----------------------------------------------------

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

# --- VALIDATE CONFIG ----------------------------------------------------------

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
$errorLog      = if ($cfg.ContainsKey('ERROR_LOG') -and $cfg['ERROR_LOG']) { $cfg['ERROR_LOG'] } else { Join-Path $ScriptDir 'oci-arm-catcher-errors.log' }

# Optional safety valve: if set to a positive integer, stop after this many
# CONSECUTIVE errors that don't match either the fatal list or the known-
# transient list (i.e. genuinely unrecognized output) - guards against
# silently hammering a broken setup forever. 0/unset = never stop on this
# basis (the default: keep trying).
$maxConsecutiveUnknown = if ($env:MAX_CONSECUTIVE_UNKNOWN) { [int]$env:MAX_CONSECUTIVE_UNKNOWN } else { 0 }

# --- RETRY CLASSIFICATION -----------------------------------------------------

# Errors that will NEVER be fixed by retrying - stop immediately on these.
$NonRetryablePattern = 'LimitExceeded|NotAuthenticated|AuthenticationFailed|NotAuthorized|AuthorizationFailed|InvalidParameter|InvalidCredentials|MissingParameter|IncorrectState|InvalidatedRetryToken|Http400|Http401|Http403|Http404|does not exist|not found in compartment|InvalidImageCompartment|InvalidSubnet|TenantIdMismatch|Usage: oci|No such option|Missing option|must be in JSON format|ConfigFileNotFound|Could not find config file|ProfileNotFound'

# Kept for quick, readable log labelling only - no longer used to decide
# whether to stop. (Not load-bearing; retry decision below defaults to true.)
$KnownTransientPattern = 'out of capacity|out of host capacity|InternalError|TooManyRequests|timed out|RequestException|ServiceUnavailable|Service Unavailable|Http5|connection reset|EOF occurred'

# --- HELPERS ------------------------------------------------------------------

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

# Parse OCI CLI JSON error output into an object with Code/Message.
# Finds ALL brace-delimited blocks and uses the LAST one that parses with a
# code/message - if the CLI ever echoes back request parameters (which can
# also look like a JSON blob) before the actual error, this avoids merging
# them into one broken blob. Falls back gracefully so we never print "?: ?".
function Get-OciError {
    param([string]$Output)
    $code = ''; $msg = ''

    $matches_ = [regex]::Matches($Output, '\{[^{}]*\}', 'Singleline')
    if ($matches_.Count -gt 0) {
        for ($i = $matches_.Count - 1; $i -ge 0; $i--) {
            try {
                $d = $matches_[$i].Value | ConvertFrom-Json -ErrorAction Stop
                $c = if ($d.PSObject.Properties['code']) { $d.code } elseif ($d.PSObject.Properties['status']) { $d.status } else { '' }
                $m = if ($d.PSObject.Properties['message']) { $d.message } else { '' }
                if ($c -or $m) {
                    $code = $c; $msg = $m
                    break
                }
            } catch { continue }
        }
    }

    if (-not $msg) {
        $line = ($Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('{') -and $_.Contains(':') } | Select-Object -First 1)
        if ($line) {
            $msg = $line
        } else {
            $lines = $Output.Trim() -split "`n"
            $msg = if ($lines.Count -gt 0) { $lines[-1] } else { '' }
        }
    }

    [pscustomobject]@{
        Code    = if ($code) { $code } else { 'Error' }
        Message = if ($msg)  { $msg }  else { 'no message' }
    }
}

# Extract the instance OCID from a successful launch response.
function Get-InstanceId {
    param([string]$Output)
    try { return ($Output | ConvertFrom-Json).data.id } catch { return 'unknown' }
}

# True unless the output matches a genuinely fatal (non-retryable) error.
# Default is TRUE (retry) - see design note above.
function Test-Retryable {
    param([string]$Output)
    -not ($Output -match $NonRetryablePattern)
}

# True if the output matches one of the well-known transient/capacity
# patterns. Used only for nicer logging (e.g. flagging truly unrecognized
# errors), not for the retry decision itself.
function Test-KnownTransient {
    param([string]$Output)
    $Output -match $KnownTransientPattern
}

# --- MAIN LOOP ----------------------------------------------------------------

Write-Host "=== oci-arm-catcher started at $(Get-Date) ==="
Write-Host "Shape: VM.Standard.A1.Flex  |  OCPU: $($cfg['OCPUS'])  |  RAM: $($cfg['MEMORY_GB'])GB"
if ($ads.Count -gt 1) {
    Write-Host "Availability Domains (rotating): $($ads -join ', ')"
} else {
    Write-Host "Availability Domain: $($ads[0])"
}
Write-Host "Retry interval: $([math]::Floor($retryInterval / 60)) min"
if ($cfg['BOOT_VOLUME_GB']) { Write-Host "Boot volume: $($cfg['BOOT_VOLUME_GB']) GB" }
Write-Host "Errors are logged to: $errorLog`n"

# Windows PowerShell 5.1 strips the inner quotes when passing a JSON string to
# a native exe, so OCI sees invalid JSON. Hand it a file:// path instead.
$shapeConfigFile = Join-Path ([System.IO.Path]::GetTempPath()) 'oci-arm-catcher-shape.json'
$shapeConfigJson = "{`"ocpus`": $($cfg['OCPUS']), `"memoryInGBs`": $($cfg['MEMORY_GB'])}"
[System.IO.File]::WriteAllText($shapeConfigFile, $shapeConfigJson)
$shapeConfig = "file://$shapeConfigFile"

# Optional boot volume size. Unset = Oracle's image default (~47 GB).
$extraArgs = @()
if ($cfg.ContainsKey('BOOT_VOLUME_GB') -and $cfg['BOOT_VOLUME_GB']) {
    $extraArgs += @('--boot-volume-size-in-gbs', $cfg['BOOT_VOLUME_GB'])
}

$attempt = 0
$adIndex = 0
$consecutiveUnknown = 0

while ($true) {
    $attempt++
    $currentAd = $ads[$adIndex]
    if ($ads.Count -gt 1) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt #$attempt  (AD: $currentAd)"
    } else {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt #$attempt"
    }

    # --no-retry is important: the OCI CLI's Python SDK has its own internal
    # retry/backoff independent of --connection-timeout/--read-timeout. On a 500
    # it can silently loop on 429 "Too Many Requests" for minutes inside a single
    # attempt, making RetryInterval meaningless and looking like a hang.
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
        @extraArgs `
        --connection-timeout  60 `
        --read-timeout        120 `
        --no-retry 2>&1 | Out-String
    $status = $LASTEXITCODE

    if ($status -eq 0) {
        $instanceId = Get-InstanceId $output
        Send-Notification "SUCCESS! Instance created: $instanceId"
        Write-Host $output
        exit 0
    }

    $err = Get-OciError $output
    Write-Host "  -> $($err.Code): $($err.Message)"

    # Always log the full raw error, regardless of classification, so it's
    # possible to review afterwards what actually happened (background/
    # unattended runs lose console scrollback).
    try {
        $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Attempt #$attempt (AD: $currentAd)`n$output`n---`n"
        Add-Content -LiteralPath $errorLog -Value $logEntry -ErrorAction Stop
    } catch {
        Write-Host "  -> (warning: could not write to error log $errorLog)" -ForegroundColor Yellow
    }

    if (Test-Retryable $output) {
        if (Test-KnownTransient $output) {
            $consecutiveUnknown = 0
        } else {
            $consecutiveUnknown++
            Write-Host "  -> (unrecognized error text, but not fatal - retrying. [$consecutiveUnknown consecutive])"
            if ($maxConsecutiveUnknown -gt 0 -and $consecutiveUnknown -ge $maxConsecutiveUnknown) {
                Write-Host "  -> Hit MAX_CONSECUTIVE_UNKNOWN ($maxConsecutiveUnknown), stopping as a precaution." -ForegroundColor Red
                Write-Host $output
                Send-Notification "Too many unrecognized errors in a row - check $errorLog"
                exit 1
            }
        }

        # Rotate to the next AD for the following attempt.
        if ($ads.Count -gt 1) { $adIndex = ($adIndex + 1) % $ads.Count }

        for ($rem = $retryInterval; $rem -gt 0; $rem--) {
            Write-Host -NoNewline ("`r  {0:00}:{1:00} until next attempt" -f [math]::Floor($rem / 60), ($rem % 60))
            Start-Sleep -Seconds 1
        }
        Write-Host "`r$((' ' * 40))`r" -NoNewline
    } else {
        Write-Host "  -> Fatal (non-retryable) error, stopping." -ForegroundColor Red
        Write-Host $output
        Send-Notification "Fatal OCI error - check the terminal / $errorLog"
        exit 1
    }
}
