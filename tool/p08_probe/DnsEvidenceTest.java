package dev.naveax.p08probe;

import java.util.Arrays;

/** Runnable without Android, a real DNS network, or production credentials. */
public final class DnsEvidenceTest {
    private static final byte[] QUERY = new byte[]{
        0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        7, 'e','x','a','m','p','l','e', 3, 'c','o','m', 0, 0, 1, 0, 1
    };
    private static int checks;

    private static void check(boolean passed, String label) {
        if (!passed) throw new AssertionError(label);
        checks++;
    }

    private static byte[] validReply() {
        byte[] reply = Arrays.copyOf(QUERY, QUERY.length);
        reply[2] = (byte)0x81; // response + standard recursive query
        reply[3] = (byte)0x80; // recursion available, NOERROR
        return reply;
    }

    public static void main(String[] args) {
        check(DnsEvidence.matchesExactQuestion(QUERY, validReply()),
                "matching full question with empty answer must count as DNS response");
        byte[] truncated = Arrays.copyOf(validReply(), 12);
        check(!DnsEvidence.matchesExactQuestion(QUERY, truncated),
                "a 12-byte QR/ID header without question must not be accepted");
        byte[] wrongId = validReply();
        wrongId[1]++;
        check(!DnsEvidence.matchesExactQuestion(QUERY, wrongId),
                "wrong transaction ID");
        byte[] noQr = validReply();
        noQr[2] = 1;
        check(!DnsEvidence.matchesExactQuestion(QUERY, noQr),
                "request incorrectly treated as a reply");
        byte[] wrongQname = validReply();
        wrongQname[14] = 'a';
        check(!DnsEvidence.matchesExactQuestion(QUERY, wrongQname),
                "wrong question name");
        byte[] wrongType = validReply();
        wrongType[QUERY.length - 3] = 28;
        check(!DnsEvidence.matchesExactQuestion(QUERY, wrongType),
                "AAAA reply to an A question");
        byte[] wrongClass = validReply();
        wrongClass[QUERY.length - 1] = 2;
        check(!DnsEvidence.matchesExactQuestion(QUERY, wrongClass),
                "wrong question class");
        byte[] wrongCount = validReply();
        wrongCount[4] = 1;
        check(!DnsEvidence.matchesExactQuestion(QUERY, wrongCount),
                "two-byte question count must be checked");
        byte[] tc = validReply();
        tc[2] |= 0x02;
        check(!DnsEvidence.matchesExactQuestion(QUERY, tc),
                "truncated DNS response is not a complete wire reply");
        byte[] opcode = validReply();
        opcode[2] |= 0x08;
        check(!DnsEvidence.matchesExactQuestion(QUERY, opcode),
                "nonstandard opcode");
        check(!DnsEvidence.matchesExactQuestion(null, validReply()),
                "null query");
        check(!DnsEvidence.matchesExactQuestion(QUERY, null),
                "null reply");
        byte[] truncatedQuestion = Arrays.copyOf(validReply(), QUERY.length - 2);
        check(!DnsEvidence.matchesExactQuestion(QUERY, truncatedQuestion),
                "truncated question must not be accepted");
        byte[] answerReply = Arrays.copyOf(validReply(), QUERY.length + 12);
        answerReply[7] = 1; // one answer; same complete question
        check(DnsEvidence.matchesExactQuestion(QUERY, answerReply),
                "additional answer bytes do not invalidate a matching question");
        System.out.println("[PASS] P0.8 DNS wire evidence: " + checks +
                " positive/negative exact-question regressions");
    }
}
