package com.github.tfox.flutter_vless.xray.utils

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class UtilitiesTest {
    @Test
    fun installAssetAtomically_preservesExistingFileWhenCopyFails() {
        val dir = testDir("failed-copy")
        val target = File(dir, "geoip.dat")
        target.writeText("known-good")

        val failingInput = object : InputStream() {
            private val bytes = "replacement".toByteArray()
            private var index = 0

            override fun read(): Int {
                if (index >= 4) throw IOException("synthetic copy failure")
                return bytes[index++].toInt() and 0xff
            }
        }

        try {
            Utilities.installAssetAtomically(failingInput, target)
            fail("A failed asset copy must be reported to the caller")
        } catch (_: IOException) {
        }

        assertEquals("known-good", target.readText())
        assertFalse(
            dir.listFiles().orEmpty().any {
                it.name.startsWith(".geoip.dat.") && it.name.endsWith(".tmp")
            },
        )
        dir.deleteRecursively()
    }

    @Test
    fun installAssetAtomically_replacesDestinationAfterCompleteCopy() {
        val dir = testDir("successful-copy")
        val target = File(dir, "geosite.dat")
        target.writeText("old")

        ByteArrayInputStream("new-complete-data".toByteArray()).use { input ->
            Utilities.installAssetAtomically(input, target)
        }

        assertEquals("new-complete-data", target.readText())
        assertFalse(
            dir.listFiles().orEmpty().any {
                it.name.endsWith(".tmp") || it.name.endsWith(".bak")
            },
        )
        dir.deleteRecursively()
    }

    private fun testDir(name: String): File {
        val dir = File("build/test-files/utilities-$name-${System.nanoTime()}")
        if (!dir.mkdirs() && !dir.isDirectory) {
            throw IOException("Unable to create test directory: ${dir.absolutePath}")
        }
        return dir
    }
}
