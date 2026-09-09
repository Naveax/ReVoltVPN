package com.github.tfox.flutter_vless.xray.utils

internal interface ManagedChildProcess {
    val isAlive: Boolean
    fun destroy()
    fun destroyForcibly()
    fun awaitExit(timeoutMillis: Long): Boolean
}

private class JavaManagedChildProcess(
    private val process: Process,
) : ManagedChildProcess {
    override val isAlive: Boolean
        get() = ProcessTerminator.isAlive(process)

    override fun destroy() {
        process.destroy()
    }

    override fun destroyForcibly() {
        // destroyForcibly() was added in Android API 26. Reflection avoids a
        // verifier/runtime dependency on that method for the runtime's minSdk 23.
        try {
            val method = Process::class.java.getMethod("destroyForcibly")
            method.invoke(process)
        } catch (_: Exception) {
            process.destroy()
        }
    }

    override fun awaitExit(timeoutMillis: Long): Boolean {
        if (!isAlive) return true
        if (timeoutMillis <= 0L) return !isAlive

        val deadlineNanos = System.nanoTime() + timeoutMillis * 1_000_000L
        while (isAlive) {
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (remainingNanos <= 0L) break
            val sleepMillis = (remainingNanos / 1_000_000L).coerceIn(1L, 25L)
            Thread.sleep(sleepMillis)
        }
        return !isAlive
    }
}

internal object ProcessTerminator {
    internal const val DEFAULT_GRACEFUL_WAIT_MS = 400L
    internal const val DEFAULT_FORCEFUL_WAIT_MS = 800L

    /** API-1-compatible liveness probe; Process.isAlive() requires API 26. */
    fun isAlive(process: Process?): Boolean {
        if (process == null) return false
        return try {
            process.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        } catch (_: Exception) {
            // If the platform cannot prove liveness, fail closed by treating the
            // child as alive rather than declaring shutdown success.
            true
        }
    }

    fun terminate(
        process: Process?,
        gracefulWaitMillis: Long = DEFAULT_GRACEFUL_WAIT_MS,
        forcefulWaitMillis: Long = DEFAULT_FORCEFUL_WAIT_MS,
    ): Boolean = terminate(
        process?.let(::JavaManagedChildProcess),
        gracefulWaitMillis,
        forcefulWaitMillis,
    )

    internal fun terminate(
        process: ManagedChildProcess?,
        gracefulWaitMillis: Long = DEFAULT_GRACEFUL_WAIT_MS,
        forcefulWaitMillis: Long = DEFAULT_FORCEFUL_WAIT_MS,
    ): Boolean {
        if (process == null || !process.isAlive) return true
        require(gracefulWaitMillis >= 0L) { "gracefulWaitMillis must be non-negative" }
        require(forcefulWaitMillis >= 0L) { "forcefulWaitMillis must be non-negative" }

        return try {
            process.destroy()
            if (process.awaitExit(gracefulWaitMillis) || !process.isAlive) return true

            process.destroyForcibly()
            process.awaitExit(forcefulWaitMillis) || !process.isAlive
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        } catch (_: Exception) {
            false
        }
    }
}
