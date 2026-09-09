package com.github.tfox.flutter_vless

import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeStartGateTest {
    @Test
    fun inactiveRuntimeWithoutGenerationAllowsStart() {
        assertEquals(
            RuntimeStartGate.Decision.ALLOW_START,
            RuntimeStartGate.decide(active = false, runtimeToken = ""),
        )
    }

    @Test
    fun activeRuntimeWithTokenMustBeAdopted() {
        assertEquals(
            RuntimeStartGate.Decision.ADOPT_EXISTING,
            RuntimeStartGate.decide(active = true, runtimeToken = "generation-1"),
        )
    }

    @Test
    fun startingGenerationTokenMustBeAdoptedBeforeActiveFlag() {
        assertEquals(
            RuntimeStartGate.Decision.ADOPT_EXISTING,
            RuntimeStartGate.decide(active = false, runtimeToken = "generation-starting"),
        )
    }

    @Test
    fun activeRuntimeWithoutTokenFailsClosed() {
        assertEquals(
            RuntimeStartGate.Decision.INVALID_ACTIVE_STATE,
            RuntimeStartGate.decide(active = true, runtimeToken = ""),
        )
    }
}
