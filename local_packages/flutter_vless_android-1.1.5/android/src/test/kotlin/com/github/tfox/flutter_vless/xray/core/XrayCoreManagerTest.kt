package com.github.tfox.flutter_vless.xray.core

import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class XrayCoreManagerTest {
    @Test
    fun buildRuntimeConfigJson_keepsSecureSocksAndSanitizesLogs() {
        val filesDir = File("build/test-files/runtime-secure")
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = runtimeConfig(
                extraLog = """
                    "log": {
                      "access": "/tmp/access.log",
                      "error": "/tmp/error.log"
                    },
                """.trimIndent(),
            )
        )

        val output = XrayCoreManager.buildRuntimeConfigJson(config, filesDir)
        val log = output.getJSONObject("log")
        val inbound = output.getJSONArray("inbounds").getJSONObject(0)
        val settings = inbound.getJSONObject("settings")
        val user = output
            .getJSONArray("outbounds")
            .getJSONObject(0)
            .getJSONObject("settings")
            .getJSONArray("vnext")
            .getJSONObject(0)
            .getJSONArray("users")
            .getJSONObject(0)

        assertEquals("none", log.getString("access"))
        assertEquals(File(filesDir, "error.log").absolutePath, log.getString("error"))
        assertEquals("revolt-secure-socks", inbound.getString("tag"))
        assertEquals("password", settings.getString("auth"))
        assertTrue(settings.getBoolean("udp"))
        assertEquals("127.0.0.1", settings.getString("ip"))
        assertEquals(19080, config.LOCAL_SOCKS5_PORT)
        assertEquals(0, config.LOCAL_HTTP_PORT)
        assertEquals(vlessEncryption, user.getString("encryption"))
        assertEquals("xtls-rprx-vision", user.getString("flow"))
    }

    @Test
    fun buildRuntimeConfigJson_keepsExplicitErrorLoggingDisabled() {
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = runtimeConfig(
                extraLog = """
                    "log": {
                      "error": "none"
                    },
                """.trimIndent(),
            )
        )

        val output = XrayCoreManager.buildRuntimeConfigJson(
            config,
            File("build/test-files/runtime-no-logs"),
        )
        val log = output.getJSONObject("log")

        assertEquals("none", log.getString("access"))
        assertEquals("none", log.getString("error"))
    }

    @Test
    fun buildRuntimeConfigJson_rejectsInvalidSecureSocks() {
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = """
                {
                  "inbounds": [
                    {
                      "tag": "revolt-secure-socks",
                      "listen": "127.0.0.1",
                      "port": 19080,
                      "protocol": "socks",
                      "settings": {
                        "auth": "noauth",
                        "udp": true,
                        "ip": "127.0.0.1",
                        "users": []
                      }
                    }
                  ],
                  "outbounds": []
                }
            """.trimIndent()
        )

        try {
            XrayCoreManager.buildRuntimeConfigJson(
                config,
                File("build/test-files/runtime-invalid-socks"),
            )
            fail("Invalid secure SOCKS5 configuration must fail closed")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("Secure SOCKS5"))
        }
    }

    @Test
    fun buildRuntimeConfigJson_normalizesXrayRuntimeAliases() {
        val config = XrayConfig(
            V2RAY_FULL_JSON_CONFIG = """
                {
                  "inbounds": [
                    {
                      "tag": "revolt-secure-socks",
                      "listen": "127.0.0.1",
                      "port": 19080,
                      "protocol": "socks",
                      "settings": {
                        "auth": "password",
                        "udp": true,
                        "ip": "127.0.0.1",
                        "users": [{"user": "runtime-user", "pass": "runtime-pass"}]
                      }
                    }
                  ],
                  "outbounds": [
                    {
                      "protocol": "vless",
                      "settings": {
                        "vnext": [
                          {
                            "address": "example.com",
                            "port": 443,
                            "users": [{"id": "11111111-1111-4111-8111-111111111111", "encryption": "none"}]
                          }
                        ]
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
            """.trimIndent()
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

    @Test
    fun buildRuntimeConfigJson_rejectsMissingOrAdditionalIngress() {
        val missing = JSONObject(runtimeConfig()).apply { remove("inbounds") }
        val empty = JSONObject(runtimeConfig()).apply {
            put("inbounds", org.json.JSONArray())
        }
        val additional = JSONObject(runtimeConfig()).apply {
            getJSONArray("inbounds").put(getJSONArray("inbounds").getJSONObject(0))
        }
        for (json in listOf(missing, empty, additional)) assertRejected(json)
    }

    @Test
    fun buildRuntimeConfigJson_rejectsMalformedIngressWithoutChangingPorts() {
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("tag", "legacy") },
            { it.put("protocol", "http") },
            { it.put("listen", "0.0.0.0") },
            { it.put("port", 1024) },
            { it.put("port", 65536) },
            { it.put("port", "19080") },
            { it.put("port", 19080.5) },
            { it.getJSONObject("settings").put("auth", "noauth") },
            { it.getJSONObject("settings").put("udp", false) },
            { it.getJSONObject("settings").put("ip", "0.0.0.0") },
            { it.getJSONObject("settings").getJSONArray("users")
                .getJSONObject(0).put("user", "") },
            { it.getJSONObject("settings").getJSONArray("users")
                .getJSONObject(0).put("pass", 123) },
            { it.getJSONObject("settings").getJSONArray("users")
                .put(JSONObject().put("user", "extra").put("pass", "extra")) }
        )
        for (mutate in mutations) {
            val json = JSONObject(runtimeConfig())
            mutate(json.getJSONArray("inbounds").getJSONObject(0))
            assertRejected(json)
        }
    }

    private fun assertRejected(json: JSONObject) {
        val config = XrayConfig(V2RAY_FULL_JSON_CONFIG = json.toString())
        val originalPort = config.LOCAL_SOCKS5_PORT
        try {
            XrayCoreManager.buildRuntimeConfigJson(config, File("build/test-files/rejected"))
            fail("Invalid ingress must fail closed")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("Secure SOCKS5"))
            assertEquals(originalPort, config.LOCAL_SOCKS5_PORT)
        }
    }

    private fun runtimeConfig(extraLog: String = ""): String = """
        {
          $extraLog
          "inbounds": [
            {
              "tag": "revolt-secure-socks",
              "listen": "127.0.0.1",
              "port": 19080,
              "protocol": "socks",
              "settings": {
                "auth": "password",
                "udp": true,
                "ip": "127.0.0.1",
                "users": [{"user": "runtime-user", "pass": "runtime-pass"}]
              }
            }
          ],
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
