package com.github.tfox.flutter_vless

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class VersionProbeTest {
    @Test
    fun readFirstLine_returnsFirstLineWithoutWaitingForProcessExit() {
        val process = FakeProcess(ByteArrayInputStream("Xray 26.7.11\nrest".toByteArray()))
        assertEquals("Xray 26.7.11", VersionProbe.readFirstLine(process, 500, 4096))
        assertTrue(process.destroyed)
    }

    @Test
    fun readFirstLine_acceptsEofWithoutNewline() {
        val process = FakeProcess(ByteArrayInputStream("Xray 26.7.11".toByteArray()))
        assertEquals("Xray 26.7.11", VersionProbe.readFirstLine(process, 500, 4096))
    }

    @Test
    fun readFirstLine_timesOutStalledInput() {
        val process = FakeProcess(object : InputStream() {
            override fun read(): Int {
                Thread.sleep(5_000)
                return -1
            }
        })
        val started = System.nanoTime()
        try {
            VersionProbe.readFirstLine(process, 50, 4096)
            fail("stalled input must time out")
        } catch (expected: IllegalStateException) {
            assertTrue((System.nanoTime() - started) / 1_000_000 < 2_000)
            assertTrue(process.destroyed)
        }
    }

    @Test
    fun readFirstLine_rejectsOversizedOutput() {
        val process = FakeProcess(ByteArrayInputStream("x".repeat(32).toByteArray()))
        try {
            VersionProbe.readFirstLine(process, 500, 8)
            fail("oversized version output must fail")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("failed"))
        }
    }

    @Test
    fun readFirstLine_preservesInterruptStatus() {
        val process = FakeProcess(object : InputStream() {
            override fun read(): Int = -1
        })
        Thread.currentThread().interrupt()
        try {
            VersionProbe.readFirstLine(process, 500, 4096)
        } catch (_: IllegalStateException) {
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }
    }

    private class FakeProcess(private val input: InputStream) : Process() {
        var destroyed = false
        override fun getOutputStream(): OutputStream = ByteArrayOutputStream()
        override fun getInputStream(): InputStream = input
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int = 0
        override fun exitValue(): Int = if (destroyed) 0 else throw IllegalThreadStateException()
        override fun destroy() {
            destroyed = true
            try { input.close() } catch (_: Exception) {}
        }
    }
}
