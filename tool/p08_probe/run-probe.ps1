# Non-destructive independent-UID probe. Does not enable/disable VPN or lockdown.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$Serial,
    [ValidateRange(10,90)][int]$TimeoutSeconds = 45
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-Adb([string[]]$AdbArguments) {
    $result = & $AdbPath -s $Serial @AdbArguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'ADB probe action failed' }
    return @($result)
}
$state = (Invoke-Adb -AdbArguments @('get-state')) -join ''
if ($state.Trim() -ne 'device') { throw 'ADB device is not ready' }
$installed = (Invoke-Adb -AdbArguments @('shell','pm','list','packages','dev.naveax.p08probe')) -join ''
if ($installed -notmatch '(?m)^package:dev\.naveax\.p08probe\s*$') {
    throw 'Independent P0.8 probe package is not installed'
}

$runId = [guid]::NewGuid().ToString('N')
Invoke-Adb -AdbArguments @('shell','am','force-stop','dev.naveax.p08probe') | Out-Null
Invoke-Adb -AdbArguments @('shell','am','start','-n','dev.naveax.p08probe/.ProbeActivity','--es','RUN_ID',$runId) | Out-Null

$records = @()
$complete = $false
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    $records = @(Invoke-Adb -AdbArguments @('logcat','-d','-s','P08Probe:I') |
        Where-Object { $_.Contains("RUN=$runId ") })
    if (@($records | Where-Object { $_.Contains("RUN=$runId PROBE_DONE") }).Count -eq 1) {
        $complete = $true
        break
    }
    Start-Sleep -Milliseconds 700
}
if (-not $complete) { throw 'Independent P0.8 probe did not reach PROBE_DONE' }

# Only a random per-invocation token is used to select THIS run. Never
# persist tokens, raw logcat, network destinations or per-UID payloads.
$names = @(
    'ACTIVE_NETWORK','IPV4_TCP','IPV4_OTHER_TCP','IPV4_TLS_END_TO_END',
    'IPV6_TCP','DNS_LOOKUP',
    'DIRECT_DNS_A_UDP53','DIRECT_DNS_AAAA_UDP53','DIRECT_DNS_A_TCP53',
    'DOT_DNS_A_TLS853','DOH_DNS_A_HTTPS443'
)
$parsed = @{}
foreach ($name in $names) {
    $pattern = 'RUN=' + [regex]::Escape($runId) + ' ' + $name + '=([^\s]+)'
    $hits = @($records | ForEach-Object { [regex]::Match($_, $pattern) } |
        Where-Object Success)
    if ($hits.Count -ne 1) { throw ('Missing or duplicate probe result: ' + $name) }
    $parsed[$name] = $hits[0].Groups[1].Value
}
$vpn = @($records | Where-Object {
    $_.Contains("RUN=$runId ACTIVE_NETWORK=") -and $_.Contains(' VPN=true ')
}).Count -eq 1
$directDnsNames = @(
    'DIRECT_DNS_A_UDP53','DIRECT_DNS_AAAA_UDP53','DIRECT_DNS_A_TCP53',
    'DOT_DNS_A_TLS853','DOH_DNS_A_HTTPS443'
)
# A DNS reply on any direct transport is an observation requiring underlay
# correlation. It is never standalone proof of a leak or an approved tunnel.
$verifiedDirectDnsReply = @($directDnsNames | Where-Object {
    $parsed[$_] -eq 'RESPONSE_VERIFIED'
}).Count -gt 0
# No-TUN network blocking can only be claimed if each new direct DNS
# transport failed before it could even connect. A UDP timeout alone is
# not proof the request never escaped through an underlay network.
$dnsConnectDenied = @($directDnsNames | Where-Object {
    $parsed[$_] -eq 'NO_VERIFIED_RESPONSE_ConnectException'
}).Count -eq $directDnsNames.Count
$noNetwork = $parsed['ACTIVE_NETWORK'] -eq 'NONE'
$noTunBlocked = $noNetwork -and (-not $vpn) -and
    $parsed['IPV4_TCP'].StartsWith('BLOCKED_') -and
    $parsed['IPV4_OTHER_TCP'].StartsWith('BLOCKED_') -and
    $parsed['IPV4_TLS_END_TO_END'].StartsWith('FAILED_') -and
    $parsed['IPV6_TCP'].StartsWith('BLOCKED_') -and
    $parsed['DNS_LOOKUP'].StartsWith('BLOCKED_')
$syntheticTunBlocked = $vpn -and
    $parsed['IPV4_TLS_END_TO_END'].StartsWith('FAILED_') -and
    $parsed['IPV6_TCP'].StartsWith('BLOCKED_') -and
    $parsed['DNS_LOOKUP'].StartsWith('BLOCKED_')
$verdict = if ($noTunBlocked -and $dnsConnectDenied -and -not $verifiedDirectDnsReply) {
    'NO_TUN_UID_NETWORK_BLOCKING_OBSERVED'
} elseif ($syntheticTunBlocked -and -not $verifiedDirectDnsReply) {
    'VPN_UID_DNS_IPV6_BLOCKED_IPV4_END_TO_END_UNPROVEN'
} else {
    'INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE'
}
[ordered]@{
    evidence_type = 'P0.8_INDEPENDENT_UID_PROBE_NOT_LEAK_ACCEPTANCE'
    timestamp_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    android_uid_is_separate_test_application = $true
    active_network = $parsed['ACTIVE_NETWORK']
    vpn_transport_reported = $vpn
    ipv4_connect_result = $parsed['IPV4_TCP']
    other_ipv4_connect_result = $parsed['IPV4_OTHER_TCP']
    ipv4_tls_end_to_end_result = $parsed['IPV4_TLS_END_TO_END']
    ipv6_result = $parsed['IPV6_TCP']
    dns_result = $parsed['DNS_LOOKUP']
    direct_dns_a_udp53 = $parsed['DIRECT_DNS_A_UDP53']
    direct_dns_aaaa_udp53 = $parsed['DIRECT_DNS_AAAA_UDP53']
    direct_dns_a_tcp53 = $parsed['DIRECT_DNS_A_TCP53']
    dot_dns_a_tls853 = $parsed['DOT_DNS_A_TLS853']
    doh_dns_a_https443 = $parsed['DOH_DNS_A_HTTPS443']
    direct_dns_valid_response_observed = [bool]$verifiedDirectDnsReply
    all_direct_dns_attempts_denied_at_connect = [bool]$dnsConnectDenied
    verdict = $verdict
    limitations = 'A verified DNS response could be carried through a legitimate VPN, and no response cannot establish no underlay packets. Physical capture is mandatory; TCP connect acknowledgement is not end-to-end forwarding evidence.'
} | ConvertTo-Json -Depth 3
