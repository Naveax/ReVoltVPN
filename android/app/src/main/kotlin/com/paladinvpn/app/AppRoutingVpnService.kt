package com.paladinvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File

class AppRoutingVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var routingProcess: Process? = null
    private var running = false

    override fun onStartCommand(intent: android.content.Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRouting()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                val policy = intent.getStringExtra(EXTRA_POLICY) ?: POLICY_SELECTED
                val packages = intent.getStringArrayListExtra(EXTRA_PACKAGES)
                    ?.map(String::trim)
                    ?.filter(String::isNotEmpty)
                    ?.distinct()
                    .orEmpty()

                if (policy == POLICY_SELECTED && packages.isEmpty()) {
                    stopRouting()
                    return START_NOT_STICKY
                }

                startForegroundNotification(policy)
                startRouting(policy, packages)
                return START_STICKY
            }

            else -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    private fun startRouting(policy: String, packages: List<String>) {
        cleanup()

        try {
            val builder = Builder()
                .setSession("ReVolt App Routing")
                .setMtu(1500)
                .addAddress("26.26.27.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            applyAppPolicy(builder, policy, packages)

            vpnInterface = builder.establish()
                ?: throw IllegalStateException("Could not establish routing interface")
            running = true
            startRoutingProcess()
        } catch (e: Exception) {
            Log.e(TAG, "App routing start failed", e)
            stopRouting()
        }
    }

    private fun applyAppPolicy(
        builder: Builder,
        policy: String,
        packages: List<String>,
    ) {
        when (policy) {
            POLICY_SELECTED -> {
                var added = 0
                for (appPackage in packages) {
                    if (appPackage == packageName) continue
                    try {
                        builder.addAllowedApplication(appPackage)
                        added++
                    } catch (e: Exception) {
                        Log.w(TAG, "Could not allow package $appPackage", e)
                    }
                }
                if (added == 0) {
                    throw IllegalStateException("No valid selected apps")
                }
            }

            POLICY_EXCLUDE -> {
                excludeOwnApp(builder)
                for (appPackage in packages) {
                    if (appPackage == packageName) continue
                    try {
                        builder.addDisallowedApplication(appPackage)
                    } catch (e: Exception) {
                        Log.w(TAG, "Could not exclude package $appPackage", e)
                    }
                }
            }

            POLICY_ALL -> {
                excludeOwnApp(builder)
            }

            else -> throw IllegalArgumentException("Unknown routing policy: $policy")
        }
    }

    private fun excludeOwnApp(builder: Builder) {
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
            Log.w(TAG, "Could not exclude ReVolt from its own routing VPN", e)
        }
    }

    private fun startRoutingProcess() {
        val tun = vpnInterface ?: return
        val executable = File(applicationInfo.nativeLibraryDir, "libtun2socks.so")
        if (!executable.exists()) {
            Log.e(TAG, "Routing binary not found")
            stopRouting()
            return
        }

        val socketFile = File(filesDir, SOCKET_FILE)
        socketFile.delete()

        val command = listOf(
            executable.absolutePath,
            "-sock-path", socketFile.absolutePath,
            "-proxy", "socks5://127.0.0.1:10807",
            "-mtu", "1500",
            "-loglevel", "warning",
        )

        try {
            routingProcess = ProcessBuilder(command)
                .redirectErrorStream(true)
                .directory(filesDir)
                .start()

            Thread {
                try {
                    routingProcess?.inputStream?.bufferedReader()?.use { reader ->
                        reader.forEachLine { line -> Log.d(TAG, line) }
                    }
                    routingProcess?.waitFor()
                } catch (_: InterruptedException) {
                } catch (e: Exception) {
                    if (running) Log.e(TAG, "Routing process monitor failed", e)
                }
            }.start()

            sendDescriptor(tun.fileDescriptor, socketFile)
        } catch (e: Exception) {
            Log.e(TAG, "Routing process start failed", e)
            stopRouting()
        }
    }

    private fun sendDescriptor(fd: java.io.FileDescriptor, socketFile: File) {
        Thread {
            repeat(10) { attempt ->
                try {
                    Thread.sleep(300)
                    val socket = LocalSocket()
                    socket.connect(
                        LocalSocketAddress(
                            socketFile.absolutePath,
                            LocalSocketAddress.Namespace.FILESYSTEM,
                        ),
                    )
                    socket.setFileDescriptorsForSend(arrayOf(fd))
                    socket.outputStream.write(32)
                    socket.setFileDescriptorsForSend(null)
                    socket.shutdownOutput()
                    socket.close()
                    return@Thread
                } catch (e: Exception) {
                    if (attempt == 9 && running) {
                        Log.e(TAG, "Descriptor transfer failed", e)
                        stopRouting()
                    }
                }
            }
        }.start()
    }

    private fun startForegroundNotification(policy: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "App routing",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }

        val icon = resources.getIdentifier("notification_icon", "drawable", packageName)
            .takeIf { it != 0 } ?: android.R.drawable.stat_sys_warning
        val routingText = when (policy) {
            POLICY_ALL -> "SOCKS routing active"
            POLICY_EXCLUDE -> "SOCKS routing with exclusions active"
            else -> "Selected app routing active"
        }

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("ReVolt VPN")
            .setContentText(routingText)
            .setSmallIcon(icon)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, SPECIAL_USE_TYPE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun cleanup() {
        running = false
        try {
            routingProcess?.destroy()
        } catch (_: Exception) {
        }
        routingProcess = null

        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        }
        vpnInterface = null

        File(filesDir, SOCKET_FILE).delete()
    }

    private fun stopRouting() {
        cleanup()
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.revoltvpn.app.routing.START"
        const val ACTION_STOP = "com.revoltvpn.app.routing.STOP"
        const val EXTRA_POLICY = "policy"
        const val EXTRA_PACKAGES = "packages"

        private const val POLICY_ALL = "all"
        private const val POLICY_EXCLUDE = "exclude"
        private const val POLICY_SELECTED = "selected"
        private const val TAG = "ReVoltAppRouting"
        private const val SOCKET_FILE = "revolt_app_routing.sock"
        private const val CHANNEL_ID = "revolt_app_routing"
        private const val NOTIFICATION_ID = 2407
        private const val SPECIAL_USE_TYPE = 0x40000000
    }
}
