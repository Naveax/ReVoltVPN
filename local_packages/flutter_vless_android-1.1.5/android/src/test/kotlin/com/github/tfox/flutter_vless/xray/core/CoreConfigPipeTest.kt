package com.github.tfox.flutter_vless.xray.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CoreConfigPipeTest {
    @Test
    fun writeAndClose_writesExactUtf8AndClosesForEof() {
        val output = TrackingOutputStream()
        val process = FakeProcess(output)
        val json = "{\"token\":\"π-secret\"}"

        CoreConfigPipe.writeAndClose(process, json, timeoutMs = 500)

        assertEquals(json, output.bytes.toString(Charsets.UTF_8))
        assertTrue(output.closed)
    }

    @Test
    fun writeAndClose_rejectsOversizedConfigBeforeWriting() {
        val output = TrackingOutputStream()
        val process = FakeProcess(output)
        try {
            CoreConfigPipe.writeAndClose(process, "x".repeat(512 * 1024 + 1), timeoutMs = 500)
            fail("oversized config must be rejected")
        } catch (expected: IllegalArgumentException) {
            assertTrue(output.bytes.size() == 0)
        }
    }

    @Test
    fun writeAndClose_boundsAStalledWriter() {
        val process = FakeProcess(object : OutputStream() {
            override fun write(b: Int) {
                Thread.sleep(5_000)
            }
            override fun write(b: ByteArray, off: Int, len: Int) {
                Thread.sleep(5_000)
            }
        })
        val started = System.nanoTime()
        try {
            CoreConfigPipe.writeAndClose(process, "{}", timeoutMs = 50)
            fail("stalled writer must time out")
        } catch (expected: IllegalStateException) {
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue("timeout must remain bounded", elapsedMs < 2_000)
        }
    }

    private class TrackingOutputStream : OutputStream() {
        val bytes = ByteArrayOutputStream()
        var closed = false
        override fun write(b: Int) = bytes.write(b)
        override fun write(b: ByteArray, off: Int, len: Int) = bytes.write(b, off, len)
        override fun close() {
            closed = true
            super.close()
        }
    }

    private class FakeProcess(private val output: OutputStream) : Process() {
        override fun getOutputStream(): OutputStream = output
        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int = 0
        override fun exitValue(): Int = 0
        override fun destroy() = Unit
    }
}
