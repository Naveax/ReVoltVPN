"""Static CI guardrails for the test-only, independent Android UID network probe.

This is deliberately not proof of network leak freedom: real device,
authoritative transport and physical underlay packet capture are separate.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
java = (root / "tool/p08_probe/ProbeActivity.java").read_text(encoding="utf-8")
wire = (root / "tool/p08_probe/DnsEvidence.java").read_text(encoding="utf-8")
wire_tests = (root / "tool/p08_probe/DnsEvidenceTest.java").read_text(encoding="utf-8")
runner = (root / "tool/p08_probe/run-probe.ps1").read_text(encoding="utf-8")
build = (root / "tool/p08_probe/build-probe.ps1").read_text(encoding="utf-8")
readme = (root / "tool/p08_probe/README.md").read_text(encoding="utf-8")
ci = (root / ".github/workflows/flutter-strict.yml").read_text(encoding="utf-8")

for method in (
    "dnsUdpResult(int qtype)",
    "dnsTcpResult()",
    "dotResult()",
    "dohResult()",
    "connectVerifiedTls(String host, int port)",
    "validDnsResponse(byte[] query, byte[] reply)",
):
    assert method in java, f"Missing response-confirming independent UID probe: {method}"

for token in (
    "new SecureRandom()",
    'return validDnsResponse(query, reply) ? "RESPONSE_VERIFIED" : "UNVERIFIED_REPLY";',
    "params.setEndpointIdentificationAlgorithm(\"HTTPS\");",
    "factory.createSocket(raw, host, port, true)",
    "socket.startHandshake();",
    "String encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(query);",
    'correctMime = true',
    'validDnsResponse(query, reply)',
    'stamp + "DIRECT_DNS_A_UDP53="',
    'stamp + "DIRECT_DNS_AAAA_UDP53="',
    'stamp + "DIRECT_DNS_A_TCP53="',
    'stamp + "DOT_DNS_A_TLS853="',
    'stamp + "DOH_DNS_A_HTTPS443="',
    'stamp + "PROBE_DONE"',
):
    assert token in java, f"Missing independent DNS reply/privacy identity gate: {token}"

assert "return DnsEvidence.matchesExactQuestion(query, reply);" in java
assert "byte[] reply = readFully(in, query.length);" in java
for token in (
    "static boolean matchesExactQuestion(byte[] query, byte[] reply)",
    "reply.length < query.length",
    "reply[0] != query[0] || reply[1] != query[1]",
    "(reply[2] & 0x80) == 0",
    "(reply[2] & 0x02) != 0",
    "(reply[4] & 0xff) != 0 || (reply[5] & 0xff) != 1",
    "for (int i = 12; i < query.length; i++)",
    "if (query[i] != reply[i]) return false;",
):
    assert token in wire, f"Missing exact DNS question validation: {token}"
assert wire_tests.count("check(") >= 14, "Missing positive and negative DNS evidence regressions"
assert "DnsEvidence.java" in build and "DnsEvidence.class" in build
assert "DnsEvidenceTest.java" in ci
assert "java -cp" in ci

# Exactly one current invocation's log token is required, and every transport
# must yield one result, rather than inheriting data from historical logcat.
for name in (
    "DIRECT_DNS_A_UDP53", "DIRECT_DNS_AAAA_UDP53", "DIRECT_DNS_A_TCP53",
    "DOT_DNS_A_TLS853", "DOH_DNS_A_HTTPS443",
):
    assert name in runner, f"Runner does not require {name}"
for token in (
    "[guid]::NewGuid().ToString('N')",
    '$_ .Contains("RUN=$runId PROBE_DONE")'.replace("$_ ", "$_"),
    "if ($hits.Count -ne 1)",
    "$verifiedDirectDnsReply",
    "'RESPONSE_VERIFIED'",
    "$dnsConnectDenied",
    "'NO_VERIFIED_RESPONSE_ConnectException'",
    "$noTunBlocked -and $dnsConnectDenied -and -not $verifiedDirectDnsReply",
    "$syntheticTunBlocked -and -not $verifiedDirectDnsReply",
    "'INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE'",
    "direct_dns_valid_response_observed",
):
    assert token in runner, f"Missing fail-conservative independent UID evidence: {token}"

assert "MANAGED_VPN_PRIVACY_PASS" not in runner
assert "P0.8_ACCEPTED" not in runner
assert "P0.8 remains BLOCKED-LIVE" in readme
assert "Physical capture is mandatory" in runner
assert "OutputDir" in build and "probe.jks" in build
assert "python3 tool/check_p08_independent_probe_contract.py" in ci
print("[PASS] P0.8 independent UID probe binds TLS hostname, validates DNS replies, and never promotes ambiguous results to leak-free acceptance.")
