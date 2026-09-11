package com.github.tfox.flutter_vless.xray.service

import android.net.ConnectivityManager
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileDescriptor
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Authenticated descriptor/DNS broker for the protected Android Xray runtime.
 *
 * Security invariants:
 * - transport sockets arrive as real SCM_RIGHTS descriptors, never process-local
 *   integer FD values;
 * - only same-UID peers may request protection or physical-network DNS;
 * - the runtime must complete an H capability handshake before VPN startup;
 * - DNS queries are bounded and are resolved on a non-VPN physical Network.
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
                    runCatching { accepted.close() }
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
                if (socket.peerCredentials.uid != Process.myUid()) return@use

                val command = socket.inputStream.read()
                val descriptors = socket.ancillaryFileDescriptors.orEmpty()
                try {
                    if (closed) return@use

                    when (command) {
                        'H'.code, 'P'.code -> handleProtectionCommand(
                            socket,
                            command,
                            descriptors,
                        )

                        'D'.code -> handleDnsCommand(socket, descriptors)
                    }
                } finally {
                    descriptors.forEach { descriptor ->
                        runCatching { Os.close(descriptor) }
                    }
                }
            }
        } catch (_: Exception) {
            // EOF, timeout, malformed requests and shutdown deliberately get no
            // positive acknowledgement. The protected runtime fails closed.
        } finally {
            clients.remove(accepted)
        }
    }

    private fun handleProtectionCommand(
        socket: LocalSocket,
        command: Int,
        descriptors: Array<out FileDescriptor>,
    ) {
        val accepted = descriptors.size == 1 &&
            ParcelFileDescriptor.dup(descriptors[0]).use { duplicate ->
                protectFd(duplicate.fd)
            }

        socket.outputStream.write(if (accepted) 1 else 0)
        socket.outputStream.flush()
        if (command == 'H'.code && accepted) {
            verified.countDown()
        }
    }

    private fun handleDnsCommand(
        socket: LocalSocket,
        descriptors: Array<out FileDescriptor>,
    ) {
        // DNS is a byte-stream RPC. It must never smuggle descriptors into the
        // broker's resolver path.
        if (descriptors.isNotEmpty()) return

        val input = DataInputStream(socket.inputStream)
        val size = input.readUnsignedShort()
        require(size in MIN_DNS_QUERY_BYTES..MAX_DNS_QUERY_BYTES)
        val query = ByteArray(size).also { input.readFully(it) }

        val network = physicalNetwork() ?: return
        val answer = XrayPhysicalDns.query(network, query)
        if (closed || answer.size > MAX_DNS_ANSWER_BYTES) return

        DataOutputStream(socket.outputStream).apply {
            writeShort(answer.size)
            write(answer)
            flush()
        }
    }

    /** Resolve against a physical link, preferring a validated one. */
    private fun physicalNetwork(): Network? {
        val manager = service.getSystemService(ConnectivityManager::class.java)
        val candidates = (listOfNotNull(manager.activeNetwork) + manager.allNetworks)
            .distinct()
        val physical = candidates.filter { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps != null &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }

        return physical.firstOrNull { network ->
            manager.getNetworkCapabilities(network)
                ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        } ?: physical.firstOrNull()
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { server.close() }
        synchronized(clients) {
            clients.forEach { socket -> runCatching { socket.close() } }
            clients.clear()
        }
        requests.shutdownNow()
        worker.interrupt()
    }

    private companion object {
        const val MIN_DNS_QUERY_BYTES = 12
        const val MAX_DNS_QUERY_BYTES = 4096
        const val MAX_DNS_ANSWER_BYTES = 65535
    }
}
