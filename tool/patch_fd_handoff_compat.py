from pathlib import Path

path = Path('third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt')
text = path.read_text()
old = '''    private fun sendFdAndWait(generation: Long): Boolean {
        val pfd = mInterface ?: return false
        val fd = pfd.fileDescriptor
        val sockPath = File(filesDir, "sock_path").absolutePath
        for (attempt in 1..12) {
            if (generation != currentGeneration ||
                stopping ||
                tun2socksProcess?.isAlive != true
            ) return false
            var socket: LocalSocket? = null
            try {
                Thread.sleep(if (attempt == 1) 120L else 250L)
                socket = LocalSocket()
                socket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM))
                socket.setFileDescriptorsForSend(arrayOf(fd))
                socket.outputStream.write(32)
                socket.outputStream.flush()
                socket.setFileDescriptorsForSend(null)
                socket.shutdownOutput()
                socket.close()
                Thread.sleep(250)
                return generation == currentGeneration &&
                    !stopping &&
                    tun2socksProcess?.isAlive == true
            } catch (_: Exception) {
                try { socket?.close() } catch (_: Exception) {}
            }
        }
        return false
    }
'''
new = '''    private fun sendFdAndWait(generation: Long): Boolean {
        val pfd = mInterface ?: return false
        val fd = pfd.fileDescriptor
        val sockPath = File(filesDir, "sock_path").absolutePath

        // flutter_vless_android 1.1.5 waits 500 ms between UDS attempts and
        // does not use Process.isAlive as a precondition for connecting to the
        // FD socket. Preserve that proven device timing while still returning
        // a real success/failure result to the hardened fail-closed caller.
        var delivered = false
        val worker = Thread {
            var tries = 0
            while (tries < 10 && generation == currentGeneration && !stopping) {
                var socket: LocalSocket? = null
                try {
                    Thread.sleep(500L)
                    socket = LocalSocket()
                    socket.connect(
                        LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM)
                    )
                    socket.setFileDescriptorsForSend(arrayOf(fd))
                    socket.outputStream.write(32)
                    socket.outputStream.flush()
                    socket.setFileDescriptorsForSend(null)
                    socket.shutdownOutput()
                    socket.close()
                    delivered = true
                    break
                } catch (_: Exception) {
                    tries++
                    try { socket?.close() } catch (_: Exception) {}
                }
            }
        }
        worker.start()
        worker.join(6000L)
        if (worker.isAlive) {
            worker.interrupt()
            return false
        }
        if (!delivered || generation != currentGeneration || stopping) return false

        // Fail closed only after the exact 1.1.5 FD transfer had a chance to
        // complete. A child that dies immediately after accepting the FD is not
        // a usable data path.
        Thread.sleep(250L)
        return tun2socksProcess?.isAlive == true
    }
'''
if new in text:
    print('FD compatibility patch already applied')
elif old not in text:
    raise SystemExit('Expected hardened sendFdAndWait block not found')
else:
    path.write_text(text.replace(old, new, 1))
    print('Applied 1.1.5-compatible FD handoff timing with fail-closed acknowledgement')
