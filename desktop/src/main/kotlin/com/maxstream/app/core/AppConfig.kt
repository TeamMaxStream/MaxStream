package com.maxstream.app.core

/**
 * Endpoint + credential configuration for the desktop client. Values mirror the
 * mobile and TV apps exactly so the desktop build talks to the same backend:
 * TMDB for catalog metadata, the Cloudflare worker for stream extraction, and
 * Firebase Auth + Realtime Database for cloud sync (watchlist + progress).
 */
object AppConfig {
    // Keep in sync with build.gradle.kts (version + nativeDistributions.packageVersion).
    const val APP_VERSION = "1.0.1"

    // TMDB (same key as mobile lib/config/api_config.dart and TV core/Constants.kt)
    const val TMDB_API_KEY = "3b65c5fdee212a85a4e4ef208d31d74e"
    const val TMDB_BASE_URL = "https://api.themoviedb.org/3"
    const val TMDB_IMAGE_BASE_URL = "https://image.tmdb.org/t/p"

    const val TMDB_POSTER_SIZE = "w500"
    const val TMDB_BACKDROP_SIZE = "w1280"
    const val TMDB_PROFILE_SIZE = "w185"

    // Stream extraction worker (same as lib/services/web_stream_service.dart)
    const val EXTRACTOR_WORKER_BASE = "https://maxstream-extractor.maxstream123.workers.dev"

    // Firebase (same app as the TV app's AuthRepository/CloudSyncRepository)
    const val FIREBASE_WEB_API_KEY = "AIzaSyAiNjTADd8kA3qi3Dgnvlyo1Vf347QnsYk"
    const val FIREBASE_AUTH_BASE = "https://identitytoolkit.googleapis.com/v1/accounts"
    const val FIREBASE_TOKEN_BASE = "https://securetoken.googleapis.com/v1/token"
    const val FIREBASE_RTDB_URL = "https://maxstream-8effc-default-rtdb.firebaseio.com"

    fun imageUrl(size: String, path: String?): String? {
        val p = path?.takeIf { it.isNotBlank() } ?: return null
        if (p.startsWith("http://") || p.startsWith("https://")) return p
        return if (p.startsWith("/")) "${TMDB_IMAGE_BASE_URL}/$size$p"
        else "${TMDB_IMAGE_BASE_URL}/$size/$p"
    }

    fun posterUrl(path: String?) = imageUrl(TMDB_POSTER_SIZE, path)
    fun backdropUrl(path: String?) = imageUrl(TMDB_BACKDROP_SIZE, path)
    fun profileUrl(path: String?) = imageUrl(TMDB_PROFILE_SIZE, path)
}