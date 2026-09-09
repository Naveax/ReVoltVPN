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
        get() = process.isAlive

    override fun destroy() {
        process.destroy()
    }

    override fun destroyForcibly() {
        // Process.destroyForcibly() is not present on every Android API level
        // supported by Flutter. Reflection keeps the call runtime-safe while
        // retaining a graceful destroy fallback on older libcore versions.
        try {
            val method = Process::class.java.getMethod("destroyForcibly")
            method.invoke(process)
        } catch (_: Exception) {
            process.destroy()
        }
    }

    override fun awaitExit(timeoutMillis: Long): Boolean {
        if (!process.isAlive) return true
        if (timeoutMillis <= 0L) return !process.isAlive

        val deadlineNanos = System.nanoTime() + timeoutMillis * 1_000_000L
        while (process.isAlive) {
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (remainingNanos <= 0L) break
            val sleepMillis = (remainingNanos / 1_000_000L).coerceIn(1L, 25L)
            Thread.sleep(sleepMillis)
        }
        return !process.isAlive
    }
}

internal object ProcessTerminator {
    internal const val DEFAULT_GRACEFUL_WAIT_MS = 400L
    internal const val DEFAULT_FORCEFUL_WAIT_MS = 800L

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
