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
        assertEquals("revolt-secure-socks", inbound.getString("tag"))
        assertEquals("password", inbound.getJSONObject("settings").getString("auth"))
        assertEquals(19080, config.LOCAL_SOCKS5_PORT)
        assertEquals(0, config.LOCAL_HTTP_PORT)
        assertEquals(vlessEncryption, user.getString("encryption"))
        assertEquals("xtls-rprx-vision", user.getString("flow"))
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
                      "settings": { "auth": "noauth", "users": [] }
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
