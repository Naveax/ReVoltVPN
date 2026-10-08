package dev.naveax.p08probe;

/**
 * Conservative DNS wire-response evidence. A matching transaction ID or DNS
 * response flag alone cannot prove a response to the exact fixture question.
 * Do not interpret valid DNS replies as underlay leak proof: the VPN may carry
 * them legitimately, and packet capture is a separate acceptance gate.
 */
final class DnsEvidence {
    private DnsEvidence() {}

    static boolean matchesExactQuestion(byte[] query, byte[] reply) {
        if (query == null || reply == null || query.length < 17 ||
                reply.length < query.length) return false;
        // DNS ID + QR, standard query opcode and a complete one-question echo.
        if (reply[0] != query[0] || reply[1] != query[1]) return false;
        if ((reply[2] & 0x80) == 0 || (reply[2] & 0x78) != 0 ||
                (reply[2] & 0x02) != 0) return false; // no truncation
        if ((reply[4] & 0xff) != 0 || (reply[5] & 0xff) != 1) return false;
        if ((query[4] & 0xff) != 0 || (query[5] & 0xff) != 1) return false;
        // Conservative: a compressed/rewritten question is unverified, not a
        // false-positive. QNAME, QTYPE and QCLASS must match the exact request.
        for (int i = 12; i < query.length; i++) {
            if (query[i] != reply[i]) return false;
        }
        return true;
    }
}
