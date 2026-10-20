package com.maxstream.app.player

import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ColorType
import org.jetbrains.skia.Data
import org.jetbrains.skia.ImageInfo
import org.jetbrains.skia.Pixmap

/**
 * One decoded frame, ready for Compose to draw.
 *
 * [data] points directly at mpv's RGB render target (there is no per-frame
 * byte-array copy); [owner] keeps the Skia bitmap/pixmap alive for as long as
 * the frame is on screen.
 */
class VideoFrame(
    val info: ImageInfo,
    val data: Data,
    val rowBytes: Int,
    val width: Int,
    val height: Int,
    val revision: Long,
    internal val owner: Any,
)

/**
 * libmpv software renderer.
 *
 * mpv draws into a small pool of RGB bitmaps. The UI thread only ever reads the
 * most recently published bitmap, while the render thread writes the next one,
 * so there is no window embedding, no AWT heavyweight surface and no platform
 * specific z-order tricks. Triple buffering leaves the UI enough time to paint
 * a frame before its buffer is reused.
 */
internal class MpvVideoRenderer(
    private val library: MpvLibrary,
    private val handle: Pointer,
) {
    private class Buffer(
        val width: Int,
        val height: Int,
        val rowBytes: Int,
        val info: ImageInfo,
        val bitmap: Bitmap,
        val pixmap: Pixmap,
        val data: Data,
    ) {
        val pointer: Pointer = Pointer(pixmap.addr)
    }

    private val updateCallback = object : MpvRenderUpdateCallback {
        override fun invoke(callbackCtx: Pointer?) = wakeUp()
    }
    private val wakeLock = Object()

    private var renderContext: Pointer? = null
    private var thread: Thread? = null
    private var buffers: Array<Buffer> = emptyArray()
    private var bufferIndex = 0
    private var currentWidth = 0
    private var currentHeight = 0
    private var sequence = 0L

    @Volatile
    private var requestedWidth = 0

    @Volatile
    private var requestedHeight = 0

    @Volatile
    private var running = false

    @Volatile
    private var wakePending = false

    @Volatile
    var frame: VideoFrame? = null
        private set

    /**
     * Creates mpv's render context. Must happen before `mpv_initialize` so mpv
     * never falls back to a windowed video output.
     */
    @Synchronized
    fun create() {
        if (renderContext != null) return

        val apiType = Memory(3L).apply { setString(0, "sw") }
        val params = paramArray(
            MpvRenderParamType.API_TYPE to apiType,
        )
        val result = Memory(Native.POINTER_SIZE.toLong())
        val rc = library.mpv_render_context_create(result, handle, params[0].pointer)
        if (rc < 0) {
            throw MpvException("mpv_render_context_create failed: ${library.mpv_error_string(rc)}")
        }
        val ctx = result.getPointer(0)
            ?: throw MpvException("mpv_render_context_create returned NULL")
        renderContext = ctx
        library.mpv_render_context_set_update_callback(ctx, updateCallback, null)
    }

    /** Starts the render thread. Call after `mpv_initialize`. */
    @Synchronized
    fun start() {
        if (thread != null) return
        create()
        running = true
        thread = Thread(::renderLoop, "maxstream-mpv-render").apply {
            isDaemon = true
            start()
        }
    }

    /** Drops the displayed image without stopping the renderer (e.g. on stop). */
    fun clearFrame() {
        frame = null
    }

    /** Sets the RGB output size in physical pixels. Safe to call from the UI thread. */
    fun setViewport(width: Int, height: Int) {
        val w = width.coerceIn(0, 8192)
        val h = height.coerceIn(0, 8192)
        if (w == requestedWidth && h == requestedHeight) return
        requestedWidth = w
        requestedHeight = h
        wakeUp()
    }

    /** Stops the render thread and destroys mpv's render context. */
    @Synchronized
    fun stop() {
        running = false
        wakeUp()
        thread?.let { t ->
            runCatching { t.join(2_000) }
            if (t.isAlive) {
                System.err.println("MpvVideoRenderer: render thread did not stop in time")
            }
        }
        thread = null

        val ctx = renderContext
        if (ctx != null) {
            runCatching { library.mpv_render_context_set_update_callback(ctx, null, null) }
            runCatching { library.mpv_render_context_free(ctx) }
                .onFailure { System.err.println("MpvVideoRenderer: free failed: $it") }
        }
        renderContext = null
        frame = null
        buffers = emptyArray()
        currentWidth = 0
        currentHeight = 0
    }

    private fun renderLoop() {
        while (running) {
            synchronized(wakeLock) { wakePending = false }

            val ctx = renderContext ?: break
            val width = requestedWidth
            val height = requestedHeight
            if (width <= 0 || height <= 0) {
                waitForUpdate(50L)
                continue
            }

            val sizeChanged = width != currentWidth || height != currentHeight
            val flags = runCatching { library.mpv_render_context_update(ctx) }
                .getOrDefault(0L)
            if (sizeChanged || flags and MpvRenderUpdate.FRAME != 0L || frame == null) {
                render(ctx, width, height)
            } else {
                waitForUpdate(16L)
            }
        }
    }

    private fun render(ctx: Pointer, width: Int, height: Int) {
        if (width != currentWidth || height != currentHeight) {
            buffers = Array(BUFFER_COUNT) { allocate(width, height) }
            bufferIndex = 0
            currentWidth = width
            currentHeight = height
        }
        val buffer = buffers[bufferIndex]

        val size = Memory(8L).apply {
            setInt(0, width)
            setInt(4, height)
        }
        val format = Memory(5L).apply { setString(0, "rgb0") }
        val stride = Memory(8L).apply { setLong(0, buffer.rowBytes.toLong()) }
        val noBlock = Memory(4L).apply { setInt(0, 0) }

        val params = paramArray(
            MpvRenderParamType.SW_SIZE to size,
            MpvRenderParamType.SW_FORMAT to format,
            MpvRenderParamType.SW_STRIDE to stride,
            // SW_POINTER's data is the pixel address itself, not a pointer to
            // a pointer; wrapping it in a Memory block makes mpv scribble the
            // video into 8 bytes of JNA heap.
            MpvRenderParamType.SW_POINTER to buffer.pointer,
            MpvRenderParamType.BLOCK_FOR_TARGET_TIME to noBlock,
        )
        val rc = library.mpv_render_context_render(ctx, params[0].pointer)
        if (rc < 0) {
            // Before the first frame mpv commonly returns UNINITIALIZED; don't
            // flood stderr while the stream is still opening.
            if (rc != -12 && rc != -3) {
                System.err.println("MpvVideoRenderer: render failed: ${library.mpv_error_string(rc)}")
            }
            return
        }

        library.mpv_render_context_report_swap(ctx)
        buffer.bitmap.notifyPixelsChanged()
        bufferIndex = (bufferIndex + 1) % buffers.size
        sequence++
        frame = VideoFrame(
            info = buffer.info,
            data = buffer.data,
            rowBytes = buffer.rowBytes,
            width = width,
            height = height,
            revision = sequence,
            owner = buffer,
        )
    }

    private fun allocate(width: Int, height: Int): Buffer {
        // mpv's software scaler is happiest with 64-byte aligned rows. Skia and
        // mpv both understand a row stride wider than width * 4.
        val rowBytes = ((width.toLong() * 4L + 63L) / 64L * 64L).toInt()
        val info = ImageInfo(width, height, ColorType.RGBA_8888, ColorAlphaType.OPAQUE)
        val bitmap = Bitmap()
        try {
            if (!bitmap.allocPixels(info, rowBytes)) {
                throw MpvException("could not allocate ${width}x$height video buffer")
            }
            val pixmap = bitmap.peekPixels()
                ?: throw MpvException("could not access ${width}x$height video buffer")
            val size = rowBytes.toLong() * height.toLong()
            if (size > Int.MAX_VALUE) throw MpvException("video buffer is too large")
            val data = Data.makeWithoutCopy(pixmap.addr, size.toInt(), pixmap)
            return Buffer(width, height, rowBytes, info, bitmap, pixmap, data)
        } catch (t: Throwable) {
            runCatching { bitmap.close() }
            throw t
        }
    }

    private fun paramArray(vararg entries: Pair<Int, Pointer>): Array<MpvRenderParam> {
        val array = MpvRenderParam()
            .toArray(entries.size + 1) as Array<MpvRenderParam>
        entries.forEachIndexed { index, (type, memory) ->
            array[index].type = type
            array[index].data = memory
        }
        array[entries.size].type = MpvRenderParamType.INVALID
        array[entries.size].data = null
        array.forEach { it.write() }
        return array
    }

    private fun wakeUp() {
        synchronized(wakeLock) {
            wakePending = true
            wakeLock.notifyAll()
        }
    }

    private fun waitForUpdate(timeoutMs: Long) {
        synchronized(wakeLock) {
            if (!wakePending && running) {
                runCatching { wakeLock.wait(timeoutMs) }
            }
        }
    }

    private companion object {
        const val BUFFER_COUNT = 3
    }
}
