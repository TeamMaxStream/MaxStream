package com.maxstream.app.data.model

import com.maxstream.app.core.AppConfig

/**
 * A catalog entry shared by the desktop UI. Maps 1:1 to a TMDB result object so
 * the same metadata the mobile/TV apps render is used on Windows (title, poster,
 * backdrop, rating, genres and release year).
 */
data class MediaItem(
    val id: String,
    val title: String,
    val mediaType: String, // "movie" | "tv"
    val overview: String,
    val year: Int? = null,
    val genres: List<String> = emptyList(),
    /** TMDB numeric genre IDs (16 animation, 10751 family = kid-safe). */
    val genreIds: List<Int> = emptyList(),
    val rating: Double = 0.0,
    /** 0.0..1.0 — how much the user has watched (Continue Watching). */
    val progress: Float = 0f,
    val posterPath: String? = null,
    val backdropPath: String? = null,
) {
    val displayYear: String get() = year?.toString() ?: ""
    val typeLabel: String get() = if (mediaType == "tv") "Series" else "Movie"
    val posterUrl: String? get() = AppConfig.posterUrl(posterPath)
    val backdropUrl: String? get() = AppConfig.backdropUrl(backdropPath)
}

/** Continue-watching entry: an item plus where playback stopped. */
data class ContinueWatch(
    val item: MediaItem,
    val progress: Float,
    val season: Int = 1,
    val episode: Int = 1,
)

/** One named rail on the home screen (Trending, Popular, Top rated…). */
data class HomeSection(
    val title: String,
    val items: List<MediaItem>,
)