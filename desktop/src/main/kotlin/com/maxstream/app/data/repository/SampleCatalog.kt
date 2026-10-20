package com.maxstream.app.data.repository

import com.maxstream.app.data.model.ContinueWatch
import com.maxstream.app.data.model.Episode
import com.maxstream.app.data.model.HomeSection
import com.maxstream.app.data.model.MediaDetails
import com.maxstream.app.data.model.MediaItem

/**
 * Offline fallback catalog. Used when TMDB is unreachable so the desktop shell
 * never renders as an empty void. Data mirrors the old static sample set.
 */
object SampleCatalog : MediaRepository {

    private val catalog = listOf(
        MediaItem(
            id = "1", title = "Neon Horizon", mediaType = "movie",
            overview = "A data courier is chased across a rain-soaked megacity after stealing the algorithm that runs it.",
            year = 2026, genres = listOf("Sci-Fi", "Thriller"), rating = 8.2,
        ),
        MediaItem(
            id = "2", title = "The Last Lighthouse", mediaType = "movie",
            overview = "Two rivals guard the final lighthouse guarding a flooded coastal nation.",
            year = 2025, genres = listOf("Drama"), rating = 7.6,
        ),
        MediaItem(
            id = "3", title = "Static Bloom", mediaType = "tv",
            overview = "A detective who sees static everywhere untangles a city-wide signal conspiracy.",
            year = 2026, genres = listOf("Crime", "Mystery"), rating = 8.8,
        ),
        MediaItem(
            id = "4", title = "Garden of Machines", mediaType = "movie",
            overview = "An AI gardener inherits a dead colony's botanical vault and must resurrect it.",
            year = 2024, genres = listOf("Sci-Fi", "Family"), genreIds = listOf(878, 10751),
            rating = 7.1,
        ),
        MediaItem(
            id = "5", title = "Tidewater", mediaType = "tv",
            overview = "Siblings fight over the family fishing empire on a shrinking boyhood island.",
            year = 2025, genres = listOf("Drama"), rating = 8.0,
        ),
        MediaItem(
            id = "6", title = "Carbon Copy", mediaType = "movie",
            overview = "A memoir ghost-writer discovers her subject is writing the same book about her.",
            year = 2026, genres = listOf("Comedy", "Drama"), rating = 6.9,
        ),
        MediaItem(
            id = "7", title = "No Signal Above", mediaType = "tv",
            overview = "Astronauts lose Earth after a solar storm and must steer a drifting station home.",
            year = 2024, genres = listOf("Sci-Fi"), rating = 8.5,
        ),
        MediaItem(
            id = "8", title = "Paper Lanterns", mediaType = "movie",
            overview = "A quiet romance in a city that turns off its lights one night a year.",
            year = 2023, genres = listOf("Romance"), rating = 7.4,
        ),
    )

    override suspend fun homeSections(): List<HomeSection> = listOf(
        HomeSection("Trending", catalog.take(6)),
        HomeSection("Popular", catalog.drop(1).take(6)),
    )

    override suspend fun continueWatching(): List<ContinueWatch> = emptyList()

    override suspend fun movies(section: MovieSection, page: Int): List<MediaItem> =
        if (page <= 1) catalog.filter { it.mediaType == "movie" } else emptyList()

    override suspend fun series(section: SeriesSection, page: Int): List<MediaItem> =
        if (page <= 1) catalog.filter { it.mediaType == "tv" } else emptyList()

    override suspend fun search(query: String, page: Int): List<MediaItem> =
        if (page > 1) emptyList()
        else if (query.isBlank()) catalog
        else catalog.filter { it.title.contains(query, ignoreCase = true) || it.genres.any { g -> g.contains(query, ignoreCase = true) } }

    override suspend fun details(id: String, mediaType: String?): MediaDetails? =
        catalog.firstOrNull { it.id == id }?.let { MediaDetails(it) }

    override suspend fun episodes(seriesId: String, season: Int): List<Episode> = emptyList()

    override suspend fun watchlist(): List<MediaItem> = emptyList()

    override suspend fun isInWatchlist(id: String): Boolean = false

    override suspend fun toggleWatchlist(item: MediaItem) = Unit

    override suspend fun saveProgress(item: MediaItem, season: Int, episode: Int, positionMs: Long, lengthMs: Long) = Unit
}