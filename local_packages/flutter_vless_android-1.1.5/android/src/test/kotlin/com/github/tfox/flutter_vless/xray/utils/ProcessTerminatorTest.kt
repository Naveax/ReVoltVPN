package com.github.tfox.flutter_vless.xray.utils

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessTerminatorTest {
    private class FakeProcess(
        private var alive: Boolean,
        private val exitOnDestroy: Boolean = false,
        private val exitOnForce: Boolean = false,
    ) : ManagedChildProcess {
        var gracefulDestroyCalls = 0
        var forceDestroyCalls = 0
        var awaitCalls = 0

        override val isAlive: Boolean
            get() = alive

        override fun destroy() {
            gracefulDestroyCalls++
            if (exitOnDestroy) alive = false
        }

        override fun destroyForcibly() {
            forceDestroyCalls++
            if (exitOnForce) alive = false
        }

        override fun awaitExit(timeoutMillis: Long): Boolean {
            awaitCalls++
            return !alive
        }
    }

    private class ExitValueProcess(
        private var alive: Boolean,
    ) : Process() {
        override fun getOutputStream(): OutputStream = ByteArrayOutputStream()
        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun getErrorStream(): InputStream = ByteArrayInputStream(ByteArray(0))
        override fun waitFor(): Int {
            alive = false
            return 0
        }
        override fun exitValue(): Int {
            if (alive) throw IllegalThreadStateException("still running")
            return 0
        }
        override fun destroy() {
            alive = false
        }
    }

    @Test
    fun `api one exitValue probe distinguishes live and exited process`() {
        val running = ExitValueProcess(alive = true)
        val exited = ExitValueProcess(alive = false)

        assertTrue(ProcessTerminator.isAlive(running))
        assertFalse(ProcessTerminator.isAlive(exited))
        assertFalse(ProcessTerminator.isAlive(null))
    }

    @Test
    fun `null or already dead process is confirmed stopped`() {
        assertTrue(ProcessTerminator.terminate(null as ManagedChildProcess?))

        val dead = FakeProcess(alive = false)
        assertTrue(ProcessTerminator.terminate(dead))
        assertTrue(dead.gracefulDestroyCalls == 0)
        assertTrue(dead.forceDestroyCalls == 0)
    }

    @Test
    fun `graceful exit is accepted without force kill`() {
        val process = FakeProcess(alive = true, exitOnDestroy = true)

        assertTrue(ProcessTerminator.terminate(process))
        assertTrue(process.gracefulDestroyCalls == 1)
        assertTrue(process.forceDestroyCalls == 0)
    }

    @Test
    fun `force kill is used when graceful stop does not exit`() {
        val process = FakeProcess(alive = true, exitOnForce = true)

        assertTrue(ProcessTerminator.terminate(process))
        assertTrue(process.gracefulDestroyCalls == 1)
        assertTrue(process.forceDestroyCalls == 1)
        assertTrue(process.awaitCalls == 2)
    }

    @Test
    fun `unkillable child process is never reported stopped`() {
        val process = FakeProcess(alive = true)

        assertFalse(ProcessTerminator.terminate(process))
        assertTrue(process.gracefulDestroyCalls == 1)
        assertTrue(process.forceDestroyCalls == 1)
        assertTrue(process.isAlive)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `negative graceful timeout is rejected`() {
        ProcessTerminator.terminate(
            FakeProcess(alive = true),
            gracefulWaitMillis = -1,
            forcefulWaitMillis = 0,
        )
    }
}
