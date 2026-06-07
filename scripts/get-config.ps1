#requires -Version 5.1
<#
.SYNOPSIS
    Prints the OCIDs you need for .env, using your existing OCI CLI config.
    Read-only: nothing is created or launched.

.EXAMPLE
    .\scripts\get-config.ps1
    .\scripts\get-config.ps1 -Compartment ocid1.compartment.oc1..xxxx -Os "Canonical Ubuntu"
#>
[CmdletBinding()]
param(
    [string]$Compartment,
    [string]$Os = 'Canonical Ubuntu'
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command oci -ErrorAction SilentlyContinue)) {
    Write-Error "'oci' CLI not found. Install it first."
    exit 1
}

function Invoke-OciJson {
    param([string[]]$OciArgs)
    try { (& oci @OciArgs 2>$null | Out-String | ConvertFrom-Json) } catch { $null }
}

Write-Host "════════════════════════════════════════════════════════════════"
Write-Host " oci-arm-catcher — config discovery"
Write-Host "════════════════════════════════════════════════════════════════"

# 1) Compartments / tenancy
$comps = Invoke-OciJson @('iam','compartment','list','--all')
if ($comps -and $comps.data) {
    $tenancy = $comps.data[0].'compartment-id'
    Write-Host "`n# Root compartment (tenancy) OCID — usable as COMPARTMENT_ID:"
    Write-Host "COMPARTMENT_ID=`"$tenancy`""
    if (-not $Compartment) { $Compartment = $tenancy }

    Write-Host "`n# All compartments (pick one for COMPARTMENT_ID):"
    foreach ($c in $comps.data) { Write-Host ("  {0}`t{1}" -f $c.name, $c.id) }
}

# 2) Availability domains
$ads = Invoke-OciJson @('iam','availability-domain','list')
Write-Host "`n# Availability Domains (AVAILABILITY_DOMAIN / AVAILABILITY_DOMAINS):"
if ($ads -and $ads.data) { foreach ($a in $ads.data) { Write-Host "  $($a.name)" } }

if ($Compartment) {
    # 3) Subnets
    $subnets = Invoke-OciJson @('network','subnet','list','--compartment-id',$Compartment,'--all')
    Write-Host "`n# Subnets in compartment (SUBNET_ID):"
    if ($subnets -and $subnets.data) {
        foreach ($s in $subnets.data) { Write-Host ("  {0}`t{1}" -f $s.'display-name', $s.id) }
    }

    # 4) Latest ARM image
    $imgs = Invoke-OciJson @('compute','image','list','--compartment-id',$Compartment,'--operating-system',$Os,'--shape','VM.Standard.A1.Flex','--all')
    Write-Host "`n# Latest ARM (A1.Flex) image for `"$Os`" (IMAGE_ID):"
    if ($imgs -and $imgs.data -and $imgs.data.Count -gt 0) {
        Write-Host ("  {0}`t{1}" -f $imgs.data[0].'display-name', $imgs.data[0].id)
    }
}

Write-Host "`n# Your SSH public key (SSH_KEY_FILE) — typical locations:"
foreach ($k in @("$HOME\.ssh\id_ed25519.pub","$HOME\.ssh\id_rsa.pub")) {
    if (Test-Path $k) { Write-Host "  $k" }
}
Write-Host "`nDone. Paste the values above into your .env (see .env.example)."
