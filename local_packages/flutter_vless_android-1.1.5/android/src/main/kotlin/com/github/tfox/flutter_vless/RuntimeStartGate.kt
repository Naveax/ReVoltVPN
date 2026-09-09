package com.github.tfox.flutter_vless

internal object RuntimeStartGate {
    enum class Decision {
        ALLOW_START,
        ADOPT_EXISTING,
        INVALID_ACTIVE_STATE,
    }

    fun decide(active: Boolean, runtimeToken: String): Decision = when {
        runtimeToken.isNotBlank() -> Decision.ADOPT_EXISTING
        active -> Decision.INVALID_ACTIVE_STATE
        else -> Decision.ALLOW_START
    }
}
