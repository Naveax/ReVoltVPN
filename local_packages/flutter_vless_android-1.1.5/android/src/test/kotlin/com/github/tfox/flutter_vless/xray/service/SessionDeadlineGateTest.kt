package com.github.tfox.flutter_vless.xray.service

import org.junit.Assert.assertEquals
import org.junit.Test

class SessionDeadlineGateTest {
    @Test
    fun allowsMatchingGenerationAndNonNegativeDeadline() {
        assertEquals(
            SessionDeadlineGate.Decision.ALLOW,
            SessionDeadlineGate.decide("runtime-a", "runtime-a", 0L),
        )
        assertEquals(
            SessionDeadlineGate.Decision.ALLOW,
            SessionDeadlineGate.decide("runtime-a", "runtime-a", 7_200L),
        )
    }

    @Test
    fun rejectsMissingActiveRuntime() {
        assertEquals(
            SessionDeadlineGate.Decision.NO_RUNTIME,
            SessionDeadlineGate.decide(null, "runtime-a", 60L),
        )
        assertEquals(
            SessionDeadlineGate.Decision.NO_RUNTIME,
            SessionDeadlineGate.decide("", "runtime-a", 60L),
        )
    }

    @Test
    fun rejectsMissingOrStaleGeneration() {
        assertEquals(
            SessionDeadlineGate.Decision.TOKEN_MISMATCH,
            SessionDeadlineGate.decide("runtime-a", null, 60L),
        )
        assertEquals(
            SessionDeadlineGate.Decision.TOKEN_MISMATCH,
            SessionDeadlineGate.decide("runtime-a", "runtime-b", 60L),
        )
    }

    @Test
    fun rejectsNegativeDeadline() {
        assertEquals(
            SessionDeadlineGate.Decision.INVALID_REMAINING,
            SessionDeadlineGate.decide("runtime-a", "runtime-a", -1L),
        )
    }
}
