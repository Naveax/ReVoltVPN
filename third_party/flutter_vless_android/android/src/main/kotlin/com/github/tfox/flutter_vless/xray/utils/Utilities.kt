package com.github.tfox.flutter_vless.xray.utils

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

object Utilities {
    fun getUserAssetsPath(context: Context): String {
        val dir = context.filesDir
        if (!dir.exists()) dir.mkdirs()
        return dir.absolutePath
    }

    fun copyAssets(context: Context) {
        val assets = context.assets
        val files = assets.list("") ?: return
        for (filename in files) {
            if (filename != "geoip.dat" && filename != "geosite.dat") continue
            var input: InputStream? = null
            var output: OutputStream? = null
            try {
                input = assets.open(filename)
                output = FileOutputStream(File(getUserAssetsPath(context), filename))
                copyFile(input, output)
            } catch (_: IOException) {
            } finally {
                try { input?.close() } catch (_: IOException) {}
                try { output?.close() } catch (_: IOException) {}
            }
        }
    }

    @Throws(IOException::class)
    private fun copyFile(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(8192)
        var read: Int
        while (input.read(buffer).also { read = it } != -1) {
            output.write(buffer, 0, read)
        }
    }
}
