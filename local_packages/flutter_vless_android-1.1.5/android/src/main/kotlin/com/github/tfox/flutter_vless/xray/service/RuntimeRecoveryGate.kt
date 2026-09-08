package com.github.tfox.flutter_vless.xray.service

/**
 * Owns one in-flight recovery operation for one runtime generation.
 *
 * cleanup/reset may allow a newer generation to acquire the gate while a stale
 * worker from the previous generation is still unwinding. release() is therefore
 * token-scoped: a stale worker can never release the newer generation's claim.
 */
internal class RuntimeRecoveryGate {
    private var ownerToken: String? = null

    @Synchronized
    fun tryAcquire(runtimeToken: String): Boolean {
        if (runtimeToken.isEmpty() || ownerToken != null) return false
        ownerToken = runtimeToken
        return true
    }

    @Synchronized
    fun release(runtimeToken: String) {
        if (ownerToken == runtimeToken) ownerToken = null
    }

    @Synchronized
    fun reset() {
        ownerToken = null
    }

    @Synchronized
    internal fun isOwnedBy(runtimeToken: String): Boolean = ownerToken == runtimeToken
}
