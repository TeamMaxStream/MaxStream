package com.maxstream.app.core

import com.maxstream.app.BuildConfig

/**
 * Compile-time configuration shared by the native TV app.
 * The TMDB key is injected at build time from `-PTMDB_API_KEY=...` (or the
 * TMDB_API_KEY environment variable) and never committed.
 */
object Constants {
    val TMDB_API_KEY: String = BuildConfig.TMDB_API_KEY
    const val TMDB_BASE_URL = "https://api.themoviedb.org/3"
    const val TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p"

    const val POSTER_SIZE = "w500"
    const val BACKDROP_SIZE = "w1280"
    const val PROFILE_SIZE = "w185"
    const val ORIGINAL_SIZE = "original"

    /** Default request timeout (seconds) for metadata + stream resolution. */
    const val NETWORK_TIMEOUT_SECONDS = 20L
}
