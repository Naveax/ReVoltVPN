package com.github.tfox.flutter_vless.xray.core

import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Writes one bounded Xray JSON configuration to stdin and closes it for EOF. */
internal object CoreConfigPipe {
    private const val DEFAULT_TIMEOUT_MS = 1_500L
    private const val MAX_CONFIG_BYTES = 512 * 1024

    fun writeAndClose(
        process: Process,
        json: String,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    ) {
        require(timeoutMs > 0L) { "timeoutMs must be positive" }
        val payload = json.toByteArray(StandardCharsets.UTF_8)
        require(payload.size <= MAX_CONFIG_BYTES) {
            "Xray runtime config exceeds $MAX_CONFIG_BYTES bytes"
        }

        val writer = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "revolt-xray-config-writer").apply { isDaemon = true }
        }
        val future = writer.submit {
            process.outputStream.use { output ->
                output.write(payload)
                output.flush()
            }
        }

        try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (error: TimeoutException) {
            future.cancel(true)
            throw IllegalStateException("Timed out writing Xray config to stdin", error)
        } catch (error: ExecutionException) {
            throw IllegalStateException(
                "Failed writing Xray config to stdin",
                error.cause ?: error,
            )
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            future.cancel(true)
            throw IllegalStateException("Interrupted while writing Xray config", error)
        } finally {
            writer.shutdownNow()
        }
    }
}
