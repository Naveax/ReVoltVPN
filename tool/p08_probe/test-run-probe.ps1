# Test-only mock ADB. Exercises REAL runner parsing and fail-conservative
# classification without a connected Android device or user network traffic.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('rvpn-p08-probe-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
$mock = Join-Path $root 'mock-adb.ps1'
$run = Join-Path $PSScriptRoot 'run-probe.ps1'
@'
$ErrorActionPreference = 'Stop'
$parts = @($args)
# A PowerShell mock does not set LASTEXITCODE as a native adb.exe does.
$global:LASTEXITCODE = 0
if ($parts -contains 'get-state') { Write-Output 'device'; return }
if ($parts -contains 'pm') { Write-Output 'package:dev.naveax.p08probe'; return }
if ($parts -contains 'am' -and $parts -contains 'start') {
    $idx = [Array]::IndexOf($parts, 'RUN_ID')
    if ($idx -lt 0 -or $idx + 1 -ge $parts.Count) { throw 'RUN_ID missing' }
    Set-Content -LiteralPath $env:P08_MOCK_TOKEN -Value $parts[$idx + 1]
    return
}
if ($parts -contains 'am' -and $parts -contains 'force-stop') { return }
if ($parts -contains 'logcat') {
    $token = (Get-Content -LiteralPath $env:P08_MOCK_TOKEN -Raw).Trim()
    $prefix = "P08Probe: RUN=$token "
    $mode = $env:P08_MOCK_MODE
    $start = 'ACTIVE_NETWORK=NONE VPN=false DNS_COUNT=-1'
    $end = 'NETWORK_END=NONE VPN=false DNS_COUNT=-1'
    $stable = 'NETWORK_STABLE=true'
    if ($mode -eq 'intermediate_change') { $stable = 'NETWORK_STABLE=false' }
    if ($mode -eq 'vpn_flip') {
        $start = 'ACTIVE_NETWORK=PRESENT VPN=true DNS_COUNT=1'
        $stable = 'NETWORK_STABLE=false'
    }
    $items = @(
        $start,
        'IPV4_TCP=BLOCKED_ConnectException',
        'IPV4_OTHER_TCP=BLOCKED_ConnectException',
        'IPV4_TLS_END_TO_END=FAILED_ConnectException',
        'IPV6_TCP=BLOCKED_ConnectException',
        'DNS_LOOKUP=BLOCKED_UnknownHostException',
        'DIRECT_DNS_A_UDP53=NO_VERIFIED_RESPONSE_ConnectException',
        'DIRECT_DNS_AAAA_UDP53=NO_VERIFIED_RESPONSE_ConnectException',
        'DIRECT_DNS_A_TCP53=NO_VERIFIED_RESPONSE_ConnectException',
        'DOT_DNS_A_TLS853=NO_VERIFIED_RESPONSE_ConnectException',
        'DOH_DNS_A_HTTPS443=NO_VERIFIED_RESPONSE_ConnectException'
    )
    if ($mode -ne 'missing_end') { $items += $end }
    if ($mode -eq 'duplicate_end') { $items += $end }
    if ($mode -eq 'probe_failed') {
        $items += 'PROBE_FAILED=NoClassDefFoundError'
    } else {
        $items += $stable
        $items += 'PROBE_DONE'
    }
    foreach ($item in $items) { Write-Output ($prefix + $item) }
    return
}
throw 'Unexpected mock ADB command'
'@ | Set-Content -LiteralPath $mock -Encoding utf8
$env:P08_MOCK_TOKEN = Join-Path $root 'run-token.txt'
$passed = 0
try {
    foreach ($case in @(
        @{ mode='stable'; expected='NO_TUN_UID_NETWORK_BLOCKING_OBSERVED' },
        @{ mode='intermediate_change'; expected='INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE' },
        @{ mode='vpn_flip'; expected='INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE' }
    )) {
        $env:P08_MOCK_MODE = $case.mode
        $json = & $run -AdbPath $mock -Serial 'test-only-fixture' -TimeoutSeconds 10
        $result = ($json | Out-String) | ConvertFrom-Json
        if ($result.verdict -cne $case.expected) {
            throw ('Wrong verdict for ' + $case.mode + ': ' + $result.verdict)
        }
        if ($case.mode -eq 'stable' -and -not $result.network_stable_across_sampled_probes) {
            throw 'Stable case marked unstable'
        }
        if ($case.mode -ne 'stable' -and $result.network_stable_across_sampled_probes) {
            throw 'Changed network falsely classified as stable'
        }
        $passed++
    }
    foreach ($mode in @('missing_end','duplicate_end','probe_failed')) {
        $env:P08_MOCK_MODE = $mode
        $failed = $false
        try { & $run -AdbPath $mock -Serial 'test-only-fixture' -TimeoutSeconds 10 | Out-Null }
        catch { $failed = $true }
        if (-not $failed) { throw ('Runner accepted invalid ' + $mode) }
        $passed++
    }
    Write-Output ('[PASS] P0.8 runner network-epoch attribution: ' + $passed + ' mock ADB regressions')
} finally {
    Remove-Item Env:P08_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:P08_MOCK_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
