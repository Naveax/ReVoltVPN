package com.github.tfox.flutter_vless.xray.service

/** Pure policy for generation-scoped session-deadline updates. */
internal object SessionDeadlineGate {
    enum class Decision {
        ALLOW,
        NO_RUNTIME,
        TOKEN_MISMATCH,
        INVALID_REMAINING,
    }

    fun decide(
        activeRuntimeToken: String?,
        requestedRuntimeToken: String?,
        remainingSeconds: Long,
    ): Decision {
        val active = activeRuntimeToken.orEmpty()
        if (active.isEmpty()) return Decision.NO_RUNTIME

        val requested = requestedRuntimeToken.orEmpty()
        if (requested.isEmpty() || requested != active) return Decision.TOKEN_MISMATCH
        if (remainingSeconds < 0L) return Decision.INVALID_REMAINING
        return Decision.ALLOW
    }
}
