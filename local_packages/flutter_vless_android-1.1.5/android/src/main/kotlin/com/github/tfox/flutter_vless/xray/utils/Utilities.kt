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
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("Unable to create Xray asset directory: ${dir.absolutePath}")
        }
        return dir.absolutePath
    }

    @Throws(IOException::class)
    fun copyAssets(context: Context) {
        val assets = context.assets
        val files = assets.list("")
            ?: throw IOException("Unable to list bundled Xray assets")
        for (filename in files) {
            if (filename == "geoip.dat" || filename == "geosite.dat") {
                val outFile = File(getUserAssetsPath(context), filename)
                assets.open(filename).use { input ->
                    installAssetAtomically(input, outFile)
                }
            }
        }
    }

    /**
     * Copies one bundled asset without ever truncating the currently installed
     * file while bytes are still being read. Failures are propagated so Xray
     * startup can fail closed instead of continuing with a partial database.
     */
    @Throws(IOException::class)
    internal fun installAssetAtomically(input: InputStream, outFile: File) {
        val parent = outFile.parentFile
            ?: throw IOException("Asset destination has no parent: ${outFile.absolutePath}")
        if (!parent.exists() && !parent.mkdirs()) {
            throw IOException("Unable to create asset directory: ${parent.absolutePath}")
        }

        val temporary = File.createTempFile(".${outFile.name}.", ".tmp", parent)
        var published = false
        try {
            FileOutputStream(temporary).use { out ->
                copyFile(input, out)
                out.fd.sync()
            }

            if (!temporary.renameTo(outFile)) {
                // File.renameTo replaces an existing file atomically on Android's
                // normal Linux filesystems. Keep a rollback path for filesystems
                // where replacement is refused instead of deleting the old copy.
                val backup = File(parent, ".${outFile.name}.bak")
                if (backup.exists() && !backup.delete()) {
                    throw IOException("Unable to clear stale asset backup: ${backup.absolutePath}")
                }
                val hadExisting = outFile.exists()
                if (hadExisting && !outFile.renameTo(backup)) {
                    throw IOException("Unable to stage existing asset: ${outFile.absolutePath}")
                }
                try {
                    if (!temporary.renameTo(outFile)) {
                        throw IOException("Unable to publish asset: ${outFile.absolutePath}")
                    }
                    published = true
                } catch (error: IOException) {
                    if (hadExisting && !outFile.exists() && backup.exists()) {
                        backup.renameTo(outFile)
                    }
                    throw error
                } finally {
                    if (published && backup.exists()) {
                        backup.delete()
                    }
                }
            } else {
                published = true
            }
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
        }
    }

    @Throws(IOException::class)
    private fun copyFile(input: InputStream, out: OutputStream) {
        val buffer = ByteArray(16 * 1024)
        var read: Int
        while (input.read(buffer).also { read = it } != -1) {
            out.write(buffer, 0, read)
        }
    }
}
