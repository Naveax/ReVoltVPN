package com.github.tfox.flutter_vless

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeControlGenerationTest {
    @Test
    fun capturedGenerationIsCurrentUntilControlMutation() {
        val generation = RuntimeControlGeneration()
        val captured = generation.capture()

        assertTrue(generation.isCurrent(captured))
        generation.advance()
        assertFalse(generation.isCurrent(captured))
    }

    @Test
    fun eachControlMutationInvalidatesOlderQueries() {
        val generation = RuntimeControlGeneration()
        val first = generation.capture()
        generation.advance()
        val second = generation.capture()
        generation.advance()

        assertFalse(generation.isCurrent(first))
        assertFalse(generation.isCurrent(second))
        assertTrue(generation.isCurrent(generation.capture()))
    }
}
