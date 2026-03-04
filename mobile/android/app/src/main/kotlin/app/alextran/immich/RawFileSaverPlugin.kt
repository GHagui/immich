package app.alextran.immich

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Flutter plugin that saves a RAW file (e.g. Canon CR3) to Android MediaStore
 * with an explicit MIME type, bypassing photo_manager's MimeTypeMap lookup.
 *
 * On Android Q+ (API 29+) the file is inserted into MediaStore.Downloads, which
 * accepts non-standard MIME types that MediaStore.Images rejects.
 * On older devices the file is written directly to DCIM/Immich and registered
 * via MediaScannerConnection.
 *
 * Channel: immich/raw_file_saver
 * Method:  saveRawFile({ filePath, title, relativePath, mimeType }) - returns String? (content URI)
 */
class RawFileSaverPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveRawFile") {
            result.notImplemented()
            return
        }

        val filePath = call.argument<String>("filePath")
        val title = call.argument<String>("title")
        val relativePath = call.argument<String>("relativePath") ?: "DCIM/Immich"
        val mimeType = call.argument<String>("mimeType")

        if (filePath == null || title == null || mimeType == null) {
            result.error("INVALID_ARGS", "filePath, title and mimeType are required", null)
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveToDownloads(filePath, title, relativePath, mimeType)
                } else {
                    saveToFilesLegacy(filePath, title, mimeType)
                }
                withContext(Dispatchers.Main) {
                    result.success(uri?.toString())
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("SAVE_ERROR", e.message, null)
                }
            }
        }
    }

    /**
     * Android Q+ path: insert into MediaStore.Downloads.
     *
     * The Downloads collection does not validate MIME types against the OS image
     * registry, so non-standard types such as "image/x-canon-cr3" are accepted.
     * IS_PENDING is used to make the write atomic; the pending record is deleted
     * on any I/O failure so no 0-byte orphan is left in the database.
     *
     * Duplicate filenames are resolved before insertion by appending a counter
     * before the extension (e.g. "IMG_5595 (1).CR3"), preventing Android from
     * appending the counter after the extension ("IMG_5595.CR3 (1)") which would
     * break the file type association.
     */
    private fun saveToDownloads(
        filePath: String,
        title: String,
        relativePath: String,
        mimeType: String,
    ): Uri? {
        val resolver = context.contentResolver

        // Remap DCIM-style paths to the Download directory tree and normalise
        // the trailing separator that MediaStore expects.
        val downloadRelativePath = relativePath
            .replaceFirst(Regex("^DCIM(?=[/\\\\]|$)"), "Download")
            .trimEnd('/', '\\') + "/"

        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uniqueTitle = resolveUniqueDownloadsName(resolver, collection, downloadRelativePath, title)

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, uniqueTitle)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, downloadRelativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = resolver.insert(collection, values) ?: return null

        try {
            val out = resolver.openOutputStream(uri)
                ?: throw IOException("openOutputStream returned null for $uri")
            out.use { FileInputStream(File(filePath)).use { src -> src.copyTo(out) } }

            val update = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            resolver.update(uri, update, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }

        return uri
    }

    /**
     * Returns a display name that does not already exist in [collection] under
     * [relativePath]. If [displayName] is taken, a counter is inserted before
     * the file extension: "IMG_5595.CR3" -> "IMG_5595 (1).CR3".
     *
     * This prevents Android from appending the counter after the extension
     * ("IMG_5595.CR3 (1)"), which would break the file type association.
     */
    private fun resolveUniqueDownloadsName(
        resolver: ContentResolver,
        collection: Uri,
        relativePath: String,
        displayName: String,
    ): String {
        val dotIndex = displayName.lastIndexOf('.')
        val baseName = if (dotIndex >= 0) displayName.substring(0, dotIndex) else displayName
        val extension = if (dotIndex >= 0) displayName.substring(dotIndex) else ""

        var candidate = displayName
        var counter = 1

        while (true) {
            val cursor = resolver.query(
                collection,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?",
                arrayOf(candidate, relativePath),
                null,
            )
            val exists = (cursor?.count ?: 0) > 0
            cursor?.close()
            if (!exists) return candidate
            candidate = "$baseName ($counter)$extension"
            counter++
        }
    }

    /**
     * Pre-Q fallback: write the file directly to DCIM/Immich on the filesystem
     * and register it with MediaScannerConnection so it appears in the gallery.
     *
     * MediaStore.Images rejects non-standard MIME types on older Android versions,
     * so we use application/octet-stream for the scanner hint and let the OS
     * determine the actual type from the file content.
     *
     * Duplicate filenames are resolved by inserting a counter before the extension
     * (e.g. "IMG_5595 (1).CR3") so the extension is always preserved.
     */
    private fun saveToFilesLegacy(
        filePath: String,
        title: String,
        mimeType: String,
    ): Uri? {
        @Suppress("DEPRECATION")
        val dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
        val destDir = File(dcimDir, "Immich")

        if (!destDir.exists() && !destDir.mkdirs()) {
            throw IOException("Failed to create directory: ${destDir.absolutePath}")
        }

        val destFile = resolveUniqueFile(destDir, title)
        FileInputStream(File(filePath)).use { input ->
            destFile.outputStream().use { output -> input.copyTo(output) }
        }

        // Use application/octet-stream so the scanner does not reject the file;
        // keep the provided mimeType only for well-known standard image types.
        val scanMimeType = if (mimeType.startsWith("image/x-") || mimeType == "image/*") {
            "application/octet-stream"
        } else {
            mimeType
        }

        var resultUri: Uri? = null
        val latch = CountDownLatch(1)
        MediaScannerConnection.scanFile(
            context,
            arrayOf(destFile.absolutePath),
            arrayOf(scanMimeType),
        ) { _, uri ->
            resultUri = uri
            latch.countDown()
        }

        val completed = latch.await(5, TimeUnit.SECONDS)
        if (!completed) {
            throw IOException("MediaScanner timed out for ${destFile.absolutePath}")
        }

        return resultUri
    }

    /**
     * Returns a [File] inside [dir] whose name does not already exist on disk.
     * If [name] is taken, a counter is inserted before the extension:
     * "IMG_5595.CR3" -> "IMG_5595 (1).CR3".
     */
    private fun resolveUniqueFile(dir: File, name: String): File {
        val dotIndex = name.lastIndexOf('.')
        val baseName = if (dotIndex >= 0) name.substring(0, dotIndex) else name
        val extension = if (dotIndex >= 0) name.substring(dotIndex) else ""

        var candidate = File(dir, name)
        var counter = 1
        while (candidate.exists()) {
            candidate = File(dir, "$baseName ($counter)$extension")
            counter++
        }
        return candidate
    }

    companion object {
        private const val CHANNEL = "immich/raw_file_saver"
    }
}
