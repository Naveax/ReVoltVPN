package com.github.tfox.flutter_vless.xray.utils

import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import java.io.Serializable

object AppConfigs {
    const val V2RAY_CONNECTION_INFO = "com.github.tfox.flutter_vless.xray.V2RAY_CONNECTION_INFO"

    enum class V2RAY_SERVICE_COMMANDS : Serializable {
        START_SERVICE, STOP_SERVICE, RESTART_SERVICE
    }

    enum class V2RAY_STATES : Serializable {
        V2RAY_CONNECTED, V2RAY_DISCONNECTED, V2RAY_CONNECTING
    }

    enum class V2RAY_CONNECTION_MODES : Serializable {
        VPN_TUN, PROXY_ONLY
    }

    @Volatile var V2RAY_STATE: V2RAY_STATES = V2RAY_STATES.V2RAY_DISCONNECTED
    @Volatile var V2RAY_CONFIG: XrayConfig? = null
    @Volatile var V2RAY_CONNECTION_MODE: V2RAY_CONNECTION_MODES = V2RAY_CONNECTION_MODES.VPN_TUN

    @Volatile var TUN_ESTABLISHED: Boolean = false
    @Volatile var FD_DELIVERED: Boolean = false
    @Volatile var SOCKS_READY: Boolean = false
    @Volatile var RUNTIME_GENERATION: Long = 0L
    @Volatile var LAST_ERROR: String = ""

    var NOTIFICATION_ICON_RESOURCE_NAME: String = ""
    var NOTIFICATION_ICON_RESOURCE_TYPE: String = ""

    fun resetReadiness(error: String = "") {
        TUN_ESTABLISHED = false
        FD_DELIVERED = false
        SOCKS_READY = false
        LAST_ERROR = error
    }

    fun isFullyReady(): Boolean =
        V2RAY_STATE == V2RAY_STATES.V2RAY_CONNECTED &&
            (V2RAY_CONNECTION_MODE == V2RAY_CONNECTION_MODES.PROXY_ONLY ||
                (TUN_ESTABLISHED && FD_DELIVERED && SOCKS_READY))
}
