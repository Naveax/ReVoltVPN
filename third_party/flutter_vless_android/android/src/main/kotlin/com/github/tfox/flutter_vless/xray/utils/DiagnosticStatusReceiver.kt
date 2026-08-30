package com.github.tfox.flutter_vless.xray.utils

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast

/**
 * Diagnostic-only receiver for the physical-device startup regression.
 *
 * It does not start, stop, restart, or otherwise mutate the VPN runtime. It only
 * observes the existing package-scoped status broadcast and surfaces the exact
 * shutdown class on the device. Remove this receiver after the regression is
 * isolated.
 */
class DiagnosticStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppConfigs.V2RAY_CONNECTION_INFO) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val previousState = prefs.getString(KEY_STATE, "") ?: ""
        val previousAt = prefs.getLong(KEY_STATE_AT, 0L)
        val previousTun = prefs.getBoolean(KEY_TUN, false)
        val previousFd = prefs.getBoolean(KEY_FD, false)
        val previousSocks = prefs.getBoolean(KEY_SOCKS, false)

        @Suppress("DEPRECATION")
        val currentState = intent.getSerializableExtra("STATE")?.toString().orEmpty()
        val tun = intent.getBooleanExtra("TUN_ESTABLISHED", false)
        val fd = intent.getBooleanExtra("FD_DELIVERED", false)
        val socks = intent.getBooleanExtra("SOCKS_READY", false)
        val generation = intent.getLongExtra("RUNTIME_GENERATION", 0L)
        val error = intent.getStringExtra("LAST_ERROR").orEmpty().trim()

        if (currentState.endsWith("DISCONNECTED")) {
            val code: String?
            val detail: String

            if (error.isNotEmpty()) {
                code = classify(error)
                detail = error
            } else if (
                previousState.endsWith("CONNECTING") &&
                previousAt > 0L &&
                now - previousAt <= STARTUP_WINDOW_MS
            ) {
                // A clean STOP_SERVICE while the previous authoritative native
                // state was CONNECTING is the signature of app/Dart-side startup
                // cleanup rather than a native fail-closed reason.
                code = "APP_STOP_DURING_STARTUP"
                detail = "App requested a clean stop while native startup was still in progress"
            } else {
                code = null
                detail = ""
            }

            if (code != null) {
                val flags = if (error.isNotEmpty()) {
                    "T=$tun FD=$fd S=$socks G=$generation"
                } else {
                    "prev T=$previousTun FD=$previousFd S=$previousSocks"
                }
                val message = "VPN DIAG: $code\n$flags\n$detail"
                Log.e(TAG, message)
                prefs.edit()
                    .putString(KEY_LAST_FAILURE, message)
                    .putLong(KEY_LAST_FAILURE_AT, now)
                    .apply()
                Toast.makeText(context.applicationContext, message, Toast.LENGTH_LONG).show()
            }
        }

        prefs.edit()
            .putString(KEY_STATE, currentState)
            .putLong(KEY_STATE_AT, now)
            .putBoolean(KEY_TUN, tun)
            .putBoolean(KEY_FD, fd)
            .putBoolean(KEY_SOCKS, socks)
            .apply()
    }

    private fun classify(error: String): String {
        val value = error.lowercase()
        return when {
            "file descriptor" in value || "fd" in value && "tun2socks" in value ->
                "FD_HANDOFF_FAIL"
            "socks5" in value && ("ready" in value || "ingress" in value) ->
                "SOCKS_READINESS_FAIL"
            "tun2socks exited" in value -> "TUN2SOCKS_EXIT"
            "tun2socks monitor" in value -> "TUN2SOCKS_MONITOR_FAIL"
            "xray" in value && "exited" in value -> "XRAY_EXIT"
            "xray" in value && "start" in value -> "XRAY_START_FAIL"
            "android refused to establish" in value -> "TUN_ESTABLISH_FAIL"
            "vpn startup was superseded" in value -> "STARTUP_SUPERSEDED"
            "vpn service destroyed" in value -> "SERVICE_DESTROYED"
            "permission revoked" in value -> "VPN_REVOKED"
            "foreground vpn service" in value -> "FOREGROUND_SERVICE_FAIL"
            "selected package" in value || "routing" in value -> "APP_ROUTING_FAIL"
            else -> "NATIVE_FAIL"
        }
    }

    companion object {
        private const val TAG = "ReVoltVpnDiag"
        private const val PREFS = "revolt_vpn_diag"
        private const val STARTUP_WINDOW_MS = 45_000L
        private const val KEY_STATE = "state"
        private const val KEY_STATE_AT = "state_at"
        private const val KEY_TUN = "tun"
        private const val KEY_FD = "fd"
        private const val KEY_SOCKS = "socks"
        private const val KEY_LAST_FAILURE = "last_failure"
        private const val KEY_LAST_FAILURE_AT = "last_failure_at"
    }
}
