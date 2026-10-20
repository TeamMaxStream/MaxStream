package com.maxstream.app.player

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Pointer
import com.sun.jna.Structure

/**
 * Minimal JNA binding for the parts of libmpv's client API used by MaxStream.
 *
 * Video goes through mpv's software render API rather than window embedding
 * (`wid`). The renderer writes RGB frames into a buffer that Compose draws like
 * any other image, so there is no heavyweight AWT surface fighting the Compose
 * z-order (and no platform-specific interop blending requirement).
 *
 * Keep this interface small and names exactly as declared in `client.h` —
 * ProGuard is told to preserve it because JNA resolves methods by name.
 */
internal interface MpvLibrary : Library {
    fun mpv_create(): Pointer?
    fun mpv_initialize(ctx: Pointer): Int
    fun mpv_terminate_destroy(ctx: Pointer)

    fun mpv_set_option_string(ctx: Pointer, name: String, value: String): Int
    fun mpv_set_option(ctx: Pointer, name: String, format: Int, data: Pointer): Int
    fun mpv_set_property_string(ctx: Pointer, name: String, value: String): Int
    fun mpv_get_property_string(ctx: Pointer, name: String): Pointer?
    fun mpv_get_property(ctx: Pointer, name: String, format: Int, data: Pointer): Int

    fun mpv_command(ctx: Pointer, args: Pointer): Int
    fun mpv_wait_event(ctx: Pointer, timeout: Double): Pointer?
    fun mpv_wakeup(ctx: Pointer)

    fun mpv_free(data: Pointer)
    fun mpv_error_string(error: Int): String?

    // ── render API (render.h) ─────────────────────────────────────────────

    fun mpv_render_context_create(res: Pointer, ctx: Pointer, params: Pointer): Int
    fun mpv_render_context_render(ctx: Pointer, params: Pointer): Int
    fun mpv_render_context_update(ctx: Pointer): Long
    fun mpv_render_context_report_swap(ctx: Pointer)
    fun mpv_render_context_free(ctx: Pointer)
    fun mpv_render_context_set_update_callback(
        ctx: Pointer,
        callback: MpvRenderUpdateCallback?,
        callbackCtx: Pointer?,
    )
}

/** `mpv_render_update_fn` — called from mpv's thread; never calls back into mpv. */
internal interface MpvRenderUpdateCallback : Callback {
    fun invoke(callbackCtx: Pointer?)
}

/** `mpv_render_param { enum type; void *data; }`. */
@Structure.FieldOrder("type", "data")
internal class MpvRenderParam() : Structure() {
    @JvmField
    var type: Int = 0

    @JvmField
    var data: Pointer? = null

    constructor(type: Int, data: Pointer?) : this() {
        this.type = type
        this.data = data
    }
}

internal object MpvFormat {
    const val NONE = 0
    const val STRING = 1
    const val FLAG = 3
    const val INT64 = 4
    const val DOUBLE = 5
}

internal object MpvRenderParamType {
    const val INVALID = 0
    const val API_TYPE = 1
    const val BLOCK_FOR_TARGET_TIME = 12
    const val SW_SIZE = 17
    const val SW_FORMAT = 18
    const val SW_STRIDE = 19
    const val SW_POINTER = 20
}

internal object MpvRenderUpdate {
    const val FRAME = 1L
}

/** Minimal libc binding: libmpv refuses to initialize when LC_NUMERIC isn't "C". */
internal interface CLibrary : Library {
    fun setlocale(category: Int, locale: String): String?
}

internal class MpvException(message: String) : RuntimeException(message)
