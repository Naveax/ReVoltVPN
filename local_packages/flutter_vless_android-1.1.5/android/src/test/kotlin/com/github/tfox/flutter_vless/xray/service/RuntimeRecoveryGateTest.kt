package com.github.tfox.flutter_vless.xray.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeRecoveryGateTest {
    @Test
    fun emptyAndConcurrentClaimsAreRejected() {
        val gate = RuntimeRecoveryGate()

        assertFalse(gate.tryAcquire(""))
        assertTrue(gate.tryAcquire("generation-a"))
        assertFalse(gate.tryAcquire("generation-a"))
        assertFalse(gate.tryAcquire("generation-b"))
        assertTrue(gate.isOwnedBy("generation-a"))
    }

    @Test
    fun currentOwnerReleaseOpensGate() {
        val gate = RuntimeRecoveryGate()

        assertTrue(gate.tryAcquire("generation-a"))
        gate.release("generation-a")
        assertFalse(gate.isOwnedBy("generation-a"))
        assertTrue(gate.tryAcquire("generation-b"))
        assertTrue(gate.isOwnedBy("generation-b"))
    }

    @Test
    fun staleReleaseCannotClearNewGenerationOwnerAfterReset() {
        val gate = RuntimeRecoveryGate()

        assertTrue(gate.tryAcquire("generation-old"))
        gate.reset()
        assertTrue(gate.tryAcquire("generation-new"))

        gate.release("generation-old")

        assertTrue(gate.isOwnedBy("generation-new"))
        assertFalse(gate.tryAcquire("generation-third"))
    }
}
