package com.github.tfox.flutter_vless.xray.service

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import java.io.Closeable
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Receives actual SCM_RIGHTS descriptors from the protected Xray runtime and
 * applies VpnService.protect(fd) to the transport socket only.
 *
 * This replaces the old addDisallowedApplication(host-package) escape hatch,
 * which is incompatible with Android lockdown / "Block connections without VPN".
 */
class XraySocketProtector(
    private val service: VpnService,
    private val protectFd: (Int) -> Boolean = service::protect,
) : Closeable {
    val socketName = "revolt-xray-protect-${UUID.randomUUID()}"

    private val server = LocalServerSocket(socketName)
    private val verified = CountDownLatch(1)
    @Volatile private var closed = false
    private val clients = Collections.synchronizedSet(mutableSetOf<LocalSocket>())
    private val requests = ThreadPoolExecutor(
        0,
        8,
        10,
        TimeUnit.SECONDS,
        SynchronousQueue(),
        { task -> Thread(task, "revolt-xray-protect-request").apply { isDaemon = true } },
    )
    private val worker = Thread({ serve() }, "revolt-xray-socket-protector").apply {
        isDaemon = true
        start()
    }

    fun awaitVerified(timeoutSeconds: Long = 3): Boolean =
        verified.await(timeoutSeconds, TimeUnit.SECONDS) && !closed

    private fun serve() {
        while (!closed) {
            try {
                val accepted = server.accept()
                clients.add(accepted)
                try {
                    requests.execute { serveClient(accepted) }
                } catch (_: Exception) {
                    clients.remove(accepted)
                    accepted.close()
                }
            } catch (_: Exception) {
                // Closing LocalServerSocket wakes accept().
            }
        }
    }

    private fun serveClient(accepted: LocalSocket) {
        try {
            accepted.use { socket ->
                socket.soTimeout = 2000
                // The broker is abstract-namespace local, but still authenticate
                // the peer UID before accepting a transported descriptor.
                if (socket.peerCredentials.uid != Process.myUid()) return@use

                val command = socket.inputStream.read()
                val descriptors = socket.ancillaryFileDescriptors.orEmpty()
                try {
                    if (closed) return@use
                    if (command != 'H'.code && command != 'P'.code) return@use

                    val acceptedProtection = descriptors.size == 1 &&
                        ParcelFileDescriptor.dup(descriptors[0]).use { duplicate ->
                            protectFd(duplicate.fd)
                        }
                    socket.outputStream.write(if (acceptedProtection) 1 else 0)
                    socket.outputStream.flush()
                    if (command == 'H'.code && acceptedProtection) {
                        verified.countDown()
                    }
                } finally {
                    descriptors.forEach { descriptor ->
                        runCatching { Os.close(descriptor) }
                    }
                }
            }
        } catch (_: Exception) {
            // EOF, timeout and shutdown deliberately produce no positive ACK.
        } finally {
            clients.remove(accepted)
        }
    }

    override fun close() {
        closed = true
        runCatching { server.close() }
        synchronized(clients) {
            clients.forEach { socket -> runCatching { socket.close() } }
        }
        requests.shutdownNow()
        worker.interrupt()
    }
}
