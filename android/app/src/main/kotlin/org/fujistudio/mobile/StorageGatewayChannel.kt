package org.fujistudio.mobile

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

class StorageGatewayChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val fdRegistry: FdRegistry,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "org.fujistudio.mobile/storage_gateway"
        private const val REQUEST_CODE_STORAGE_PERMISSION = 9101
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val decodeExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    private val tempCounter = AtomicLong(0L)

    @Volatile
    private var pendingPermissionResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        fdRegistry.closeAll()
        ioExecutor.shutdown()
        decodeExecutor.shutdown()
        pendingPermissionResult = null
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        @Suppress("UNUSED_PARAMETER") grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_STORAGE_PERMISSION) {
            return false
        }
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        pending?.success(getPermissionStateString())
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPermissionState" -> {
                result.success(getPermissionStateString())
            }
            "requestReadPermission" -> {
                handleRequestReadPermission(result)
            }
            "listAlbums" -> {
                ioExecutor.execute {
                    runOnResult(result) { queryAlbums() }
                }
            }
            "listMediaInAlbum" -> {
                val albumId = call.argument<String>("albumId") ?: ""
                val limit = call.argument<Int>("limit") ?: 200
                val offset = call.argument<Int>("offset") ?: 0
                ioExecutor.execute {
                    runOnResult(result) { queryMediaInAlbum(albumId, limit, offset) }
                }
            }
            "openReadOnlyFd" -> {
                val uriStr = call.argument<String>("uri") ?: ""
                ioExecutor.execute {
                    runOnResult(result) {
                        if (uriStr.isBlank()) {
                            null
                        } else {
                            val entry = fdRegistry.openReadOnly(
                                activity.contentResolver,
                                Uri.parse(uriStr),
                            )
                            entry?.let {
                                mapOf(
                                    "handleId" to it.handleId,
                                    "fd" to it.fd,
                                    "sizeBytes" to it.sizeBytes,
                                )
                            }
                        }
                    }
                }
            }
            "closeFd" -> {
                val handleId = call.argument<String>("handleId") ?: ""
                ioExecutor.execute {
                    runOnResult(result) {
                        if (handleId.isNotEmpty()) {
                            fdRegistry.close(handleId)
                        }
                        null
                    }
                }
            }
            "closeAllFds" -> {
                ioExecutor.execute {
                    runOnResult(result) {
                        fdRegistry.closeAll()
                        null
                    }
                }
            }
            "decodeToProxyJpeg" -> {
                val source = call.argument<String>("source") ?: ""
                val isContentUri = call.argument<Boolean>("isContentUri") ?: false
                val outJpegPath = call.argument<String>("outJpegPath") ?: ""
                val maxLongEdge = call.argument<Int>("maxLongEdge") ?: 1600
                val orientationOverride = call.argument<Int>("orientationOverride")
                decodeExecutor.execute {
                    runOnResult(result) {
                        decodeToProxyJpeg(
                            source = source,
                            isContentUri = isContentUri,
                            outJpegPath = outJpegPath,
                            maxLongEdge = maxLongEdge,
                            orientationOverride = orientationOverride,
                        )
                    }
                }
            }
            "getProxyCacheDirectory" -> {
                ioExecutor.execute {
                    runOnResult(result) {
                        val dir = File(activity.cacheDir, "proxy_v1")
                        if (!dir.exists()) {
                            dir.mkdirs()
                        }
                        dir.absolutePath
                    }
                }
            }
            "getSessionStorageDirectory" -> {
                ioExecutor.execute {
                    runOnResult(result) {
                        val dir = File(activity.filesDir, "sessions")
                        if (!dir.exists()) {
                            dir.mkdirs()
                        }
                        dir.absolutePath
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun <T> runOnResult(result: MethodChannel.Result, block: () -> T) {
        try {
            val value = block()
            mainHandler.post { result.success(value) }
        } catch (t: Throwable) {
            mainHandler.post {
                result.error("STORAGE_GATEWAY_ERROR", t.message ?: t.javaClass.simpleName, null)
            }
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun getPermissionStateString(): String {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                when {
                    hasPermission(Manifest.permission.READ_MEDIA_IMAGES) -> "granted"
                    hasPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "limited"
                    else -> "denied"
                }
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                if (hasPermission(Manifest.permission.READ_MEDIA_IMAGES)) "granted" else "denied"
            }
            else -> {
                if (hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE)) "granted" else "denied"
            }
        }
    }

    private fun handleRequestReadPermission(result: MethodChannel.Result) {
        val current = getPermissionStateString()
        if (current == "granted") {
            result.success("granted")
            return
        }
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_IN_FLIGHT", "Permission request already in progress", null)
            return
        }
        pendingPermissionResult = result
        val permissions = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                arrayOf(
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
                )
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
            }
            else -> {
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        }
        activity.requestPermissions(permissions, REQUEST_CODE_STORAGE_PERMISSION)
    }

    private data class AlbumAccumulator(
        val albumId: String,
        val name: String,
        var count: Int = 0,
        var coverUri: String? = null,
        var coverIsImage: Boolean = false,
        var newestDateModified: Long = Long.MIN_VALUE,
    )

    private fun queryAlbums(): List<Map<String, Any?>> {
        val seenIds = HashSet<Long>(512)
        val albums = LinkedHashMap<String, AlbumAccumulator>()

        fun scanCollection(
            collectionUri: Uri,
            selection: String?,
            selectionArgs: Array<String>?,
            isImageTable: Boolean,
        ) {
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.Images.ImageColumns.BUCKET_ID,
                MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_MODIFIED,
            )
            activity.contentResolver.query(
                collectionUri,
                projection,
                selection,
                selectionArgs,
                "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
                val bucketIdIdx = cursor.getColumnIndex(MediaStore.Images.ImageColumns.BUCKET_ID)
                val bucketNameIdx = cursor.getColumnIndex(MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME)
                val modifiedIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)

                while (cursor.moveToNext()) {
                    if (idIdx < 0 || bucketIdIdx < 0) continue
                    val id = cursor.getLong(idIdx)
                    if (!seenIds.add(id)) continue

                    val bucketId = cursor.getString(bucketIdIdx) ?: continue
                    val bucketName = if (bucketNameIdx >= 0) {
                        cursor.getString(bucketNameIdx) ?: "Unknown"
                    } else {
                        "Unknown"
                    }
                    val modified = if (modifiedIdx >= 0) cursor.getLong(modifiedIdx) else 0L
                    val itemUri = ContentUris.withAppendedId(collectionUri, id).toString()

                    val acc = albums.getOrPut(bucketId) {
                        AlbumAccumulator(albumId = bucketId, name = bucketName)
                    }
                    acc.count += 1
                    val shouldReplaceCover = acc.coverUri == null ||
                        (!acc.coverIsImage && isImageTable) ||
                        (acc.coverIsImage == isImageTable && modified > acc.newestDateModified)
                    if (shouldReplaceCover) {
                        acc.coverUri = itemUri
                        acc.coverIsImage = isImageTable
                        acc.newestDateModified = modified
                    }
                }
            }
        }

        scanCollection(
            collectionUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            selection = null,
            selectionArgs = null,
            isImageTable = true,
        )

        val filesUri = MediaStore.Files.getContentUri("external")
        scanCollection(
            collectionUri = filesUri,
            selection = "(${MediaStore.MediaColumns.MIME_TYPE} = ? OR LOWER(${MediaStore.MediaColumns.DISPLAY_NAME}) LIKE ?)",
            selectionArgs = arrayOf("image/x-fuji-raf", "%.raf"),
            isImageTable = false,
        )

        return albums.values
            .sortedWith(compareByDescending<AlbumAccumulator> { it.newestDateModified }.thenBy { it.name.lowercase(Locale.US) })
            .map { acc ->
                mapOf(
                    "albumId" to acc.albumId,
                    "name" to acc.name,
                    "count" to acc.count,
                    "coverUri" to acc.coverUri,
                )
            }
    }

    private data class QueriedMediaRow(
        val mediaId: String,
        val uri: String,
        val displayName: String,
        val relativePath: String,
        val mimeType: String,
        val sizeBytes: Long,
        val dateTakenMs: Long?,
        val dateModifiedSec: Long,
        val width: Int?,
        val height: Int?,
    )

    private fun queryMediaInAlbum(
        albumId: String,
        limit: Int,
        offset: Int,
    ): List<Map<String, Any?>> {
        if (albumId.isBlank() || limit <= 0 || offset < 0) {
            return emptyList()
        }

        val seenIds = HashSet<Long>(256)
        val rows = ArrayList<QueriedMediaRow>()

        fun scanCollection(
            collectionUri: Uri,
            selection: String,
            selectionArgs: Array<String>,
        ) {
            val projectionList = mutableListOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.SIZE,
                MediaStore.Images.ImageColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.WIDTH,
                MediaStore.MediaColumns.HEIGHT,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                projectionList.add(MediaStore.MediaColumns.RELATIVE_PATH)
            } else {
                @Suppress("DEPRECATION")
                projectionList.add(MediaStore.MediaColumns.DATA)
            }

            activity.contentResolver.query(
                collectionUri,
                projectionList.toTypedArray(),
                selection,
                selectionArgs,
                null,
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
                val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
                val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                val takenIdx = cursor.getColumnIndex(MediaStore.Images.ImageColumns.DATE_TAKEN)
                val modifiedIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)
                val widthIdx = cursor.getColumnIndex(MediaStore.MediaColumns.WIDTH)
                val heightIdx = cursor.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
                val relPathIdx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                } else {
                    @Suppress("DEPRECATION")
                    cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                }

                while (cursor.moveToNext()) {
                    if (idIdx < 0) continue
                    val id = cursor.getLong(idIdx)
                    if (!seenIds.add(id)) continue

                    val displayName = if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else ""
                    val mimeType = if (mimeIdx >= 0) cursor.getString(mimeIdx) ?: "" else ""
                    val sizeBytes = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                    val dateTakenMs = if (takenIdx >= 0 && !cursor.isNull(takenIdx)) {
                        cursor.getLong(takenIdx)
                    } else {
                        null
                    }
                    val dateModifiedSec = if (modifiedIdx >= 0) cursor.getLong(modifiedIdx) else 0L
                    val width = if (widthIdx >= 0 && !cursor.isNull(widthIdx)) {
                        cursor.getInt(widthIdx).takeIf { it > 0 }
                    } else {
                        null
                    }
                    val height = if (heightIdx >= 0 && !cursor.isNull(heightIdx)) {
                        cursor.getInt(heightIdx).takeIf { it > 0 }
                    } else {
                        null
                    }
                    val rawRelPath = if (relPathIdx >= 0) cursor.getString(relPathIdx) ?: "" else ""
                    val relPath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        rawRelPath
                    } else {
                        File(rawRelPath).parent ?: ""
                    }

                    rows.add(
                        QueriedMediaRow(
                            mediaId = id.toString(),
                            uri = ContentUris.withAppendedId(collectionUri, id).toString(),
                            displayName = displayName,
                            relativePath = relPath,
                            mimeType = mimeType,
                            sizeBytes = sizeBytes,
                            dateTakenMs = dateTakenMs,
                            dateModifiedSec = dateModifiedSec,
                            width = width,
                            height = height,
                        ),
                    )
                }
            }
        }

        scanCollection(
            collectionUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            selection = "${MediaStore.Images.ImageColumns.BUCKET_ID} = ?",
            selectionArgs = arrayOf(albumId),
        )

        val filesUri = MediaStore.Files.getContentUri("external")
        scanCollection(
            collectionUri = filesUri,
            selection = "${MediaStore.Images.ImageColumns.BUCKET_ID} = ? AND (${MediaStore.MediaColumns.MIME_TYPE} = ? OR LOWER(${MediaStore.MediaColumns.DISPLAY_NAME}) LIKE ?)",
            selectionArgs = arrayOf(albumId, "image/x-fuji-raf", "%.raf"),
        )

        rows.sortWith(
            compareByDescending<QueriedMediaRow> { it.dateTakenMs ?: (it.dateModifiedSec * 1000L) }
                .thenBy { it.displayName.lowercase(Locale.US) },
        )

        if (offset >= rows.size) {
            return emptyList()
        }
        val end = min(rows.size, offset + limit)
        return rows.subList(offset, end).map { r ->
            mapOf(
                "mediaId" to r.mediaId,
                "uri" to r.uri,
                "displayName" to r.displayName,
                "relativePath" to r.relativePath,
                "mimeType" to r.mimeType,
                "sizeBytes" to r.sizeBytes,
                "dateTakenMs" to r.dateTakenMs,
                "dateModifiedSec" to r.dateModifiedSec,
                "width" to r.width,
                "height" to r.height,
            )
        }
    }

    private fun decodeToProxyJpeg(
        source: String,
        isContentUri: Boolean,
        outJpegPath: String,
        maxLongEdge: Int,
        orientationOverride: Int?,
    ): Map<String, Any> {
        require(source.isNotBlank()) { "decodeToProxyJpeg source cannot be blank" }
        require(outJpegPath.isNotBlank()) { "decodeToProxyJpeg outJpegPath cannot be blank" }
        val targetMaxEdge = max(1, maxLongEdge)

        // Step 1: Bounds pass
        val boundsOpts = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        decodeBitmapStreamOrFile(source, isContentUri, boundsOpts)
        val rawW = boundsOpts.outWidth
        val rawH = boundsOpts.outHeight
        require(rawW > 0 && rawH > 0) { "Failed to decode image bounds for $source" }

        // Step 2: Compute power-of-2 inSampleSize keeping sampled long edge >= targetMaxEdge
        var inSampleSize = 1
        val rawLongEdge = max(rawW, rawH)
        while ((rawLongEdge / (inSampleSize * 2)) >= targetMaxEdge) {
            inSampleSize *= 2
        }

        // Step 3: Decode subsampled bitmap & apply EXIF orientation + final scale
        val decodeOpts = BitmapFactory.Options().apply {
            this.inSampleSize = inSampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = decodeBitmapStreamOrFile(source, isContentUri, decodeOpts)
            ?: throw IllegalStateException("BitmapFactory failed to decode $source")

        val orientation = orientationOverride ?: readExifOrientation(source, isContentUri)
        val transformed = transformBitmapForProxy(decoded, orientation, targetMaxEdge)
        if (transformed !== decoded) {
            decoded.recycle()
        }

        val finalW = transformed.width
        val finalH = transformed.height

        // Step 4: Atomic JPEG quality 85 write
        val outFile = File(outJpegPath)
        outFile.parentFile?.mkdirs()
        val reqId = tempCounter.incrementAndGet()
        val tmpFile = File("${outFile.absolutePath}.tmp.$reqId")
        try {
            FileOutputStream(tmpFile).use { fos ->
                val ok = transformed.compress(Bitmap.CompressFormat.JPEG, 85, fos)
                if (!ok) {
                    throw IllegalStateException("Bitmap.compress(JPEG) returned false")
                }
                fos.flush()
                runCatching { fos.fd.sync() }
            }
            if (!tmpFile.renameTo(outFile)) {
                if (outFile.exists()) {
                    outFile.delete()
                }
                if (!tmpFile.renameTo(outFile)) {
                    throw IllegalStateException("Failed atomic rename to ${outFile.absolutePath}")
                }
            }
        } catch (t: Throwable) {
            tmpFile.delete()
            throw t
        } finally {
            transformed.recycle()
        }

        return mapOf(
            "width" to finalW,
            "height" to finalH,
            "byteSize" to outFile.length(),
        )
    }

    private fun decodeBitmapStreamOrFile(
        source: String,
        isContentUri: Boolean,
        opts: BitmapFactory.Options,
    ): Bitmap? {
        return if (isContentUri) {
            val uri = Uri.parse(source)
            activity.contentResolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream, null, opts)
            }
        } else {
            BitmapFactory.decodeFile(source, opts)
        }
    }

    private fun readExifOrientation(source: String, isContentUri: Boolean): Int {
        return runCatching {
            val exif = if (isContentUri) {
                activity.contentResolver.openInputStream(Uri.parse(source))?.use { stream ->
                    ExifInterface(stream)
                }
            } else {
                ExifInterface(source)
            }
            exif?.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            ) ?: ExifInterface.ORIENTATION_NORMAL
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
    }

    private fun transformBitmapForProxy(
        src: Bitmap,
        orientation: Int,
        maxLongEdge: Int,
    ): Bitmap {
        val swapsAxes = orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270

        val orientedW = if (swapsAxes) src.height else src.width
        val orientedH = if (swapsAxes) src.width else src.height
        val orientedLong = max(orientedW, orientedH)
        val scale = if (orientedLong > maxLongEdge) {
            maxLongEdge.toFloat() / orientedLong.toFloat()
        } else {
            1.0f
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            else -> Unit
        }
        if (scale < 1.0f) {
            matrix.postScale(scale, scale)
        }
        if (matrix.isIdentity) {
            return src
        }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
    }
}
