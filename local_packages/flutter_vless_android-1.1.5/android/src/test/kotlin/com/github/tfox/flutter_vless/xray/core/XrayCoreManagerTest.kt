package com.github.tfox.flutter_vless.xray.core

import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class XrayCoreManagerTest {
    @Test
    fun buildRuntimeConfigJson_keepsOnlyAuthenticatedEphemeralSocksAndSanitizesLogs() {
        val filesDir = File("build/test-files/runtime-secure")
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = runtimeConfig(
                extraLog = """
                    "log": {
                      "access": "/tmp/access.log",
                      "error": "/tmp/error.log"
                    },
                """.trimIndent(),
            ),
        )

        val output = XrayCoreManager.buildRuntimeConfigJson(config, filesDir)
        val log = output.getJSONObject("log")
        val inbounds = output.getJSONArray("inbounds")
        val inbound = inbounds.getJSONObject(0)
        val settings = inbound.getJSONObject("settings")
        val account = settings.getJSONArray("users").getJSONObject(0)
        val user = output
            .getJSONArray("outbounds")
            .getJSONObject(0)
            .getJSONObject("settings")
            .getJSONArray("vnext")
            .getJSONObject(0)
            .getJSONArray("users")
            .getJSONObject(0)

        assertFalse(log.has("access"))
        assertEquals(File(filesDir, "error.log").absolutePath, log.getString("error"))
        assertEquals(1, inbounds.length())
        assertEquals("revolt-secure-socks", inbound.getString("tag"))
        assertEquals("127.0.0.1", inbound.getString("listen"))
        assertEquals("socks", inbound.getString("protocol"))
        assertEquals(55080, inbound.getInt("port"))
        assertEquals("password", settings.getString("auth"))
        assertTrue(settings.getBoolean("udp"))
        assertEquals("127.0.0.1", settings.getString("ip"))
        assertEquals(1, settings.getJSONArray("users").length())
        assertEquals("runtime-user", account.getString("user"))
        assertEquals("runtime-pass", account.getString("pass"))
        assertEquals(55080, config.LOCAL_SOCKS5_PORT)
        assertEquals(0, config.LOCAL_HTTP_PORT)
        assertEquals(vlessEncryption, user.getString("encryption"))
        assertEquals("xtls-rprx-vision", user.getString("flow"))
    }

    @Test
    fun buildRuntimeConfigJson_rejectsNoAuthSecureTag() {
        assertRejected(
            """
            {
              "inbounds": [{
                "tag": "revolt-secure-socks",
                "listen": "127.0.0.1",
                "port": 55080,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": true, "ip": "127.0.0.1", "users": []}
              }],
              "outbounds": []
            }
            """.trimIndent(),
        )
    }

    @Test
    fun buildRuntimeConfigJson_rejectsMissingSecureInboundInsteadOfInjectingFallback() {
        assertRejected(
            """
            {
              "inbounds": [],
              "outbounds": []
            }
            """.trimIndent(),
        )
    }

    @Test
    fun buildRuntimeConfigJson_rejectsExtraHttpOrSocksInbound() {
        assertRejected(
            """
            {
              "inbounds": [
                ${secureInbound()},
                {
                  "tag": "legacy-http",
                  "listen": "127.0.0.1",
                  "port": 55081,
                  "protocol": "http",
                  "settings": {}
                }
              ],
              "outbounds": []
            }
            """.trimIndent(),
        )
    }

    @Test
    fun buildRuntimeConfigJson_rejectsNonEphemeralPort() {
        assertRejected(runtimeConfig(port = 19080))
    }

    @Test
    fun buildRuntimeConfigJson_rejectsUdpDisabled() {
        assertRejected(runtimeConfig(udp = false))
    }

    @Test
    fun buildRuntimeConfigJson_normalizesXrayRuntimeAliases() {
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = """
                {
                  "inbounds": [${secureInbound()}],
                  "outbounds": [
                    {
                      "protocol": "vless",
                      "settings": {
                        "vnext": [{
                          "address": "example.com",
                          "port": 443,
                          "users": [{"id": "11111111-1111-4111-8111-111111111111", "encryption": "none"}]
                        }]
                      },
                      "streamSettings": {
                        "network": "XHTTP",
                        "security": "tls",
                        "tlsSettings": {"allowInsecure": false, "serverName": "example.com"},
                        "xHTTPSettings": {"path": "/", "mode": "auto"},
                        "httpUpgradeSettings": {"path": "/upgrade"},
                        "splitHTTPSettings": {"path": "/split"}
                      }
                    }
                  ]
                }
            """.trimIndent(),
        )

        val output = XrayCoreManager.buildRuntimeConfigJson(
            config,
            File("build/test-files/runtime-aliases"),
        )
        val stream = output
            .getJSONArray("outbounds")
            .getJSONObject(0)
            .getJSONObject("streamSettings")

        assertEquals("xhttp", stream.getString("network"))
        assertTrue(stream.has("xhttpSettings"))
        assertTrue(stream.has("httpupgradeSettings"))
        assertTrue(stream.has("splithttpSettings"))
        assertFalse(stream.has("xHTTPSettings"))
        assertFalse(stream.has("httpUpgradeSettings"))
        assertFalse(stream.has("splitHTTPSettings"))
        assertFalse(stream.getJSONObject("tlsSettings").has("allowInsecure"))
    }

    private fun assertRejected(configJson: String) {
        val config = XrayConfig(V2RAY_FULL_JSON_CONFIG = configJson)
        try {
            XrayCoreManager.buildRuntimeConfigJson(
                config,
                File("build/test-files/runtime-rejected"),
            )
            fail("Unsafe local ingress must fail closed")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().isNotEmpty())
        }
    }

    private fun secureInbound(port: Int = 55080, udp: Boolean = true): String = """
        {
          "tag": "revolt-secure-socks",
          "listen": "127.0.0.1",
          "port": $port,
          "protocol": "socks",
          "settings": {
            "auth": "password",
            "udp": $udp,
            "ip": "127.0.0.1",
            "users": [{"user": "runtime-user", "pass": "runtime-pass"}]
          }
        }
    """.trimIndent()

    private fun runtimeConfig(
        extraLog: String = "",
        port: Int = 55080,
        udp: Boolean = true,
    ): String = """
        {
          $extraLog
          "inbounds": [${secureInbound(port, udp)}],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "vless",
              "settings": {
                "address": "xhttp.example.com",
                "port": 443,
                "id": "b94da146-a56e-49d7-af4c-a68c9065cbfd",
                "encryption": "$vlessEncryption",
                "flow": "xtls-rprx-vision",
                "level": 8
              },
              "streamSettings": {"network": "xhttp", "security": "none"}
            }
          ]
        }
    """.trimIndent()

    private companion object {
        const val vlessEncryption =
            "mlkem768x25519plus.native.1rtt.100-500-2000.75-0-100.80-0-5000.gtmOXB2AN_r905czmOIr6dKq_YDdEJB8RWGqfsXurns"
    }
}
