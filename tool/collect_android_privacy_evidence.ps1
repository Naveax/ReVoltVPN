# Read-only P0.8 preflight. This DOES NOT simulate a VPN or claim leak-proofness.
# Output intentionally omits serial number, IPs, hostnames and raw dumpsys/logcat.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$Serial,
    [string]$ApkPath
)
$ErrorActionPreference = 'Stop'

function Get-AdbText([string[]]$Arguments) {
    $lines = & $AdbPath -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('ADB command failed: ' + ($Arguments -join ' '))
    }
    return ($lines -join [environment]::NewLine)
}

$api = (Get-AdbText -Arguments @('shell','getprop','ro.build.version.sdk')).Trim()
$release = (Get-AdbText -Arguments @('shell','getprop','ro.build.version.release')).Trim()
$packages = Get-AdbText -Arguments @('shell','pm','list','packages','com.paladinvpn.app')
$vpn = Get-AdbText -Arguments @('shell','dumpsys','vpn_management')
$conn = Get-AdbText -Arguments @('shell','dumpsys','connectivity')
$links = Get-AdbText -Arguments @('shell','cat','/proc/net/dev')

$installed = $packages -match '(?m)^package:com\.paladinvpn\.app\s*$'
$owner = $vpn -match 'Active package name:\s*com\.paladinvpn\.app'
$tunInterface = [regex]::IsMatch($links, '(?m)^\s*tun\d+:')
$virtualResolverAdvertised = $conn.Contains('198.18.0.2')
$vpnLink = [regex]::IsMatch($conn, 'InterfaceName:\s*tun\d+')
# Historical transitions are not proof of the presently enforced lockdown.
$historicalLockdownEvent = [regex]::Matches(
    $vpn,'Mode changed: lockdown=(true|false) alwaysOn=(true|false)'
) | Select-Object -First 1
$lastEvent = if ($historicalLockdownEvent) { $historicalLockdownEvent.Value } else { 'unavailable' }

$apkSha = $null
if ($ApkPath) {
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        throw 'Provided APK path does not exist.'
    }
    $apkSha = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$status = if (-not $installed) { 'BLOCKED_NO_CLIENT' }
          elseif (-not $tunInterface -or -not $vpnLink) { 'BLOCKED_NO_ESTABLISHED_TUN' }
          elseif (-not $virtualResolverAdvertised) { 'BLOCKED_NO_VIRTUAL_DNS_PROOF' }
          else { 'TUN_DNS_OBSERVED_LIVE_LEAK_TESTS_STILL_REQUIRED' }

[ordered]@{
    evidence_type = 'P0.8_READ_ONLY_PREFLIGHT_NOT_LEAK_ACCEPTANCE'
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    android_api = $api
    android_release = $release
    vpn_package_installed = [bool]$installed
    vpn_owner_matches = [bool]$owner
    tun_interface_present = [bool]$tunInterface
    tun_linkproperties_present = [bool]$vpnLink
    virtual_dns_observed = [bool]$virtualResolverAdvertised
    last_lockdown_transition_not_current_proof = $lastEvent
    local_apk_sha256_not_installed_binary_attestation = $apkSha
    verdict = $status
    required_remaining_tests = @(
        'real server-backed TUN establishment',
        'independent UID IPv4+IPv6+DNS A/AAAA/DoT/DoH probes',
        'underlay packet capture with expected-transport allowlist',
        'lockdown enabled/disabled and VPN process death comparison',
        'physical dual-stack network; Wi-Fi/mobile changes; reconnect'
    )
} | ConvertTo-Json -Depth 4
