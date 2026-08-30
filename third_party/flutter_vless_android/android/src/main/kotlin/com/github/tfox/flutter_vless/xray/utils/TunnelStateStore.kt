package com.github.tfox.flutter_vless.xray.utils

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * App-private cross-process snapshot of the native VPN runtime.
 *
 * The Xray/VpnService runs in :RunSoLibXrayDaemon while Flutter runs in the
 * main process, so in-memory AppConfigs and broadcast delivery cannot be used
 * as an authoritative readiness query. The remote process writes this file
 * atomically whenever readiness/state changes; the Flutter process only reads
 * it and therefore cannot accidentally start/stop the VPN while observing it.
 */
object TunnelStateStore {
    private const val STATE_FILE = "revolt_vpn_state.json"
    private const val TEMP_FILE = "revolt_vpn_state.json.tmp"

    @Synchronized
    fun write(context: Context) {
        val config = AppConfigs.V2RAY_CONFIG
        val state = when (AppConfigs.V2RAY_STATE) {
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> "CONNECTED"
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
            AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED -> "DISCONNECTED"
        }
        val json = JSONObject()
            .put("state", state)
            .put("tunEstablished", AppConfigs.TUN_ESTABLISHED)
            .put("fdDelivered", AppConfigs.FD_DELIVERED)
            .put("socksReady", AppConfigs.SOCKS_READY)
            .put("socksPort", config?.LOCAL_SOCKS5_PORT ?: 0)
            .put("socksUser", config?.LOCAL_SOCKS5_USER.orEmpty())
            .put("socksPass", config?.LOCAL_SOCKS5_PASS.orEmpty())
            .put("generation", AppConfigs.RUNTIME_GENERATION)
            .put("error", AppConfigs.LAST_ERROR)

        val target = File(context.filesDir, STATE_FILE)
        val temp = File(context.filesDir, TEMP_FILE)
        try {
            temp.writeText(json.toString())
            if (!temp.renameTo(target)) {
                target.writeText(json.toString())
                temp.delete()
            }
        } catch (_: Exception) {
            // Broadcast/event delivery remains available as a non-authoritative
            // UI signal. A failed snapshot write must never tear down the VPN.
            temp.delete()
        }
    }

    fun read(context: Context): Map<String, Any> {
        val target = File(context.filesDir, STATE_FILE)
        if (!target.isFile) return emptyState()
        return try {
            val json = JSONObject(target.readText())
            mapOf(
                "state" to json.optString("state", "DISCONNECTED"),
                "tunEstablished" to json.optBoolean("tunEstablished", false),
                "fdDelivered" to json.optBoolean("fdDelivered", false),
                "socksReady" to json.optBoolean("socksReady", false),
                "socksPort" to json.optInt("socksPort", 0),
                "socksUser" to json.optString("socksUser", ""),
                "socksPass" to json.optString("socksPass", ""),
                "generation" to json.optLong("generation", 0L),
                "error" to json.optString("error", "")
            )
        } catch (_: Exception) {
            emptyState()
        }
    }

    private fun emptyState(): Map<String, Any> = mapOf(
        "state" to "DISCONNECTED",
        "tunEstablished" to false,
        "fdDelivered" to false,
        "socksReady" to false,
        "socksPort" to 0,
        "socksUser" to "",
        "socksPass" to "",
        "generation" to 0L,
        "error" to ""
    )
}
