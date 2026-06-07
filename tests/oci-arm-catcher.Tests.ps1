# Pester tests for oci-arm-catcher.ps1
#
# Run:  Invoke-Pester -Path tests/oci-arm-catcher.Tests.ps1
#
# Strategy: put a fake `oci` (and `oci.bat`/`oci.cmd`) on PATH whose behaviour
# is driven by env vars, then run the script with a temp .env and assert on
# exit code and output.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Script   = Join-Path $RepoRoot 'oci-arm-catcher.ps1'
    $script:Tmp      = Join-Path ([System.IO.Path]::GetTempPath()) ("oac-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

    # Fake oci CLI as a PowerShell script wrapped in a .cmd shim so it's found on PATH.
    $bin = Join-Path $Tmp 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $fakePs = Join-Path $bin 'fake-oci.ps1'
@'
switch ($env:MOCK_MODE) {
  'success'  { Write-Output '{"data": {"id": "ocid1.instance.oc1..success"}}'; exit 0 }
  'capacity' { [Console]::Error.WriteLine('{"code": "InternalError", "message": "Out of host capacity."}'); exit 1 }
  'fatal'    { [Console]::Error.WriteLine('{"code": "NotAuthorizedOrNotFound", "message": "Authorization failed."}'); exit 1 }
  default    { Write-Output '{"data": {"id": "ocid1.instance.oc1..success"}}'; exit 0 }
}
'@ | Set-Content -Path $fakePs -Encoding UTF8

    $shim = Join-Path $bin 'oci.cmd'
    "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-oci.ps1`" %*" | Set-Content -Path $shim -Encoding ASCII

    $script:OldPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"

    # Minimal valid .env
    $sshKey = Join-Path $Tmp 'id_ed25519.pub'
    'ssh-ed25519 AAAATESTKEY test@example' | Set-Content -Path $sshKey
    $script:EnvFile = Join-Path $Tmp 'test.env'
@"
COMPARTMENT_ID="ocid1.tenancy.oc1..test"
DISPLAY_NAME="arm-free-1"
SSH_KEY_FILE="$sshKey"
AVAILABILITY_DOMAIN="Test:EU-AMSTERDAM-1-AD-1"
SUBNET_ID="ocid1.subnet.oc1..test"
IMAGE_ID="ocid1.image.oc1..test"
OCPUS=4
MEMORY_GB=24
RETRY_INTERVAL=1
"@ | Set-Content -Path $EnvFile -Encoding UTF8
}

AfterAll {
    $env:PATH = $script:OldPath
    Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue
}

Describe 'oci-arm-catcher.ps1' {

    It 'launches successfully and exits 0' {
        $env:MOCK_MODE = 'success'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script -ConfigFile $EnvFile 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'SUCCESS'
        $out | Should -Match 'ocid1.instance.oc1..success'
    }

    It 'stops on a non-retryable error with exit 1' {
        $env:MOCK_MODE = 'fatal'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script -ConfigFile $EnvFile 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'Unexpected error'
    }

    It 'fails fast when the config file is missing' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script -ConfigFile (Join-Path $Tmp 'nope.env') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'not found'
    }
}
