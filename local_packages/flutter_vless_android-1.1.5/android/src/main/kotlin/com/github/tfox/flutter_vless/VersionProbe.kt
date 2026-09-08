package com.github.tfox.flutter_vless

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal object VersionProbe {
    private const val DEFAULT_TIMEOUT_MS = 3_000L
    private const val DEFAULT_MAX_BYTES = 4_096

    fun query(
        executable: File,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        maxBytes: Int = DEFAULT_MAX_BYTES,
    ): String {
        require(executable.isFile) { "Xray executable not found" }
        val process = ProcessBuilder(executable.absolutePath, "-version")
            .redirectErrorStream(true)
            .start()
        return readFirstLine(process, timeoutMs, maxBytes)
    }

    internal fun readFirstLine(
        process: Process,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        maxBytes: Int = DEFAULT_MAX_BYTES,
    ): String {
        require(timeoutMs > 0L) { "timeoutMs must be positive" }
        require(maxBytes > 0) { "maxBytes must be positive" }

        val readerExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "revolt-xray-version-reader").apply { isDaemon = true }
        }
        val readFuture = readerExecutor.submit<String> {
            process.inputStream.use { input ->
                val bytes = ByteArrayOutputStream()
                while (true) {
                    val value = input.read()
                    if (value < 0 || value == '\n'.code) break
                    if (bytes.size() >= maxBytes) {
                        throw IllegalStateException("Xray version output exceeds $maxBytes bytes")
                    }
                    if (value != '\r'.code) bytes.write(value)
                }
                bytes.toString(StandardCharsets.UTF_8.name())
            }
        }

        try {
            return readFuture.get(timeoutMs, TimeUnit.MILLISECONDS).ifBlank {
                "Xray version unavailable"
            }
        } catch (error: TimeoutException) {
            readFuture.cancel(true)
            throw IllegalStateException("Xray version probe timed out", error)
        } catch (error: ExecutionException) {
            throw IllegalStateException(
                "Xray version probe failed",
                error.cause ?: error,
            )
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            readFuture.cancel(true)
            throw IllegalStateException("Xray version probe interrupted", error)
        } finally {
            try {
                process.destroy()
            } catch (_: Exception) {
            }
            readFuture.cancel(true)
            readerExecutor.shutdownNow()
        }
    }
}
