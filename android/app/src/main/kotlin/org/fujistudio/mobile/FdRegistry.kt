package org.fujistudio.mobile

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Tracks active read-only [ParcelFileDescriptor] instances opened on behalf of
 * the Dart/C++ layer without ever calling `detachFd()`.
 *
 * Closing via [close] or [closeAll] releases kernel file descriptors safely.
 */
class FdRegistry {
    data class OpenedFdEntry(
        val handleId: String,
        val fd: Int,
        val sizeBytes: Long,
    )

    private val openFds = ConcurrentHashMap<String, ParcelFileDescriptor>()

    fun openReadOnly(contentResolver: ContentResolver, uri: Uri): OpenedFdEntry? {
        val pfd = contentResolver.openFileDescriptor(uri, "r") ?: return null
        val fd = pfd.fd
        if (fd < 0) {
            runCatching { pfd.close() }
            return null
        }
        val handleId = UUID.randomUUID().toString()
        openFds[handleId] = pfd
        val statSize = pfd.statSize
        return OpenedFdEntry(
            handleId = handleId,
            fd = fd,
            sizeBytes = if (statSize >= 0L) statSize else 0L,
        )
    }

    fun close(handleId: String) {
        val pfd = openFds.remove(handleId) ?: return
        runCatching { pfd.close() }
    }

    fun closeAll() {
        val keys = openFds.keys.toList()
        for (key in keys) {
            val pfd = openFds.remove(key)
            if (pfd != null) {
                runCatching { pfd.close() }
            }
        }
    }
}
