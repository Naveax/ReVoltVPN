package com.github.tfox.flutter_vless.xray.service

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Resolve Xray system DNS on the current physical Android Network.
 *
 * Android 29+ uses DnsResolver.rawQuery on that Network, preserving the
 * platform's Private DNS policy. Android 23-28 can only perform network-scoped
 * address lookups, so only IN A/AAAA queries are implemented there; every other
 * query returns NOTIMP instead of silently escaping through a process-global
 * resolver.
 */
internal object XrayPhysicalDns {
    fun query(network: Network, query: ByteArray): ByteArray {
        require(query.size in 12..4096) { "Invalid physical DNS query size" }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return addressQuery(query) { host ->
                network.getAllByName(host).map { address -> address.address }
            }
        }

        val done = CountDownLatch(1)
        val cancellation = CancellationSignal()
        var answer: ByteArray? = null
        try {
            DnsResolver.getInstance().rawQuery(
                network,
                query,
                DnsResolver.FLAG_EMPTY,
                { task -> task.run() },
                cancellation,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(result: ByteArray, rcode: Int) {
                        // rawQuery returns the complete DNS wire response. A
                        // non-zero rcode is still a valid resolver response.
                        answer = result
                        done.countDown()
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        done.countDown()
                    }
                },
            )
            check(done.await(DNS_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                "Physical DNS timeout"
            }
            return checkNotNull(answer) { "Physical DNS failed" }
        } finally {
            cancellation.cancel()
        }
    }

    /** Pure DNS-wire fallback used on API 23-28 and unit-testable on the JVM. */
    internal fun addressQuery(
        query: ByteArray,
        lookup: (String) -> List<ByteArray>,
    ): ByteArray {
        require(query.size >= 12) { "DNS header truncated" }
        require(query[4].toInt() == 0 && query[5].toInt() == 1) {
            "Expected exactly one DNS question"
        }

        var offset = 12
        val labels = mutableListOf<String>()
        while (true) {
            require(offset < query.size) { "DNS name truncated" }
            val length = query[offset++].toInt() and 0xff
            if (length == 0) break
            require(length <= 63 && offset + length <= query.size) {
                "Invalid DNS label"
            }
            labels += String(query, offset, length, Charsets.US_ASCII)
            offset += length
        }

        require(labels.isNotEmpty()) { "Empty DNS name" }
        require(offset + 4 <= query.size) { "DNS question truncated" }
        val type = ((query[offset].toInt() and 0xff) shl 8) or
            (query[offset + 1].toInt() and 0xff)
        val clazz = ((query[offset + 2].toInt() and 0xff) shl 8) or
            (query[offset + 3].toInt() and 0xff)
        offset += 4

        val supported = clazz == DNS_CLASS_IN &&
            (type == DNS_TYPE_A || type == DNS_TYPE_AAAA)
        val addressSize = if (type == DNS_TYPE_A) 4 else 16
        val addresses = if (supported) {
            lookup(labels.joinToString(".")).filter { it.size == addressSize }
        } else {
            emptyList()
        }

        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { out ->
            // Keep the transaction ID, set QR/RD/RA and either NOERROR or
            // NOTIMP. We intentionally do not synthesize answers for other
            // record types on Android versions lacking rawQuery.
            out.write(query, 0, 2)
            out.writeShort(if (supported) 0x8180 else 0x8184)
            out.writeShort(1)
            out.writeShort(addresses.size)
            out.writeShort(0)
            out.writeShort(0)
            out.write(query, 12, offset - 12)

            for (address in addresses) {
                out.writeShort(0xc00c)
                out.writeShort(type)
                out.writeShort(DNS_CLASS_IN)
                out.writeInt(0)
                out.writeShort(address.size)
                out.write(address)
            }
        }
        return bytes.toByteArray()
    }

    private const val DNS_TIMEOUT_SECONDS = 10L
    private const val DNS_CLASS_IN = 1
    private const val DNS_TYPE_A = 1
    private const val DNS_TYPE_AAAA = 28
}
