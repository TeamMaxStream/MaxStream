package com.maxstream.app.data.repository

import com.maxstream.app.data.KidsMode
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.visibleForActiveProfile
import com.maxstream.app.data.cloud.CloudSync
import com.maxstream.app.data.model.ContinueWatch
import com.maxstream.app.data.model.Episode
import com.maxstream.app.data.model.HomeSection
import com.maxstream.app.data.model.MediaDetails
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.remote.TmdbClient

/**
 * Primary desktop data source. Reads catalog/metadata from the real TMDB API
 * (same endpoints and key as mobile + TV), and wires watchlist + progress
 * through Firebase cloud sync with the local watch-state store as the offline
 * merge target. Every network call falls back to [SampleCatalog] so the app
 * still renders when offline.
 */
object TmdbRepository : MediaRepository {

    private val client = TmdbClient()

    override suspend fun homeSections(): List<HomeSection> = runCatching {
        client.genres("movie")
        client.genres("tv")
        listOf(
            HomeSection("Trending movies", client.array("/trending/movie/week").map(client::parseMedia)),
            HomeSection("Trending series", client.array("/trending/tv/week").map(client::parseMedia)),
            HomeSection("Popular movies", client.array("/movie/popular").map(client::parseMedia)),
            HomeSection("Popular series", client.array("/tv/popular").map(client::parseMedia)),
            HomeSection(
                "Top rated",
                (client.array("/movie/top_rated").map(client::parseMedia) +
                    client.array("/tv/top_rated").map(client::parseMedia)).distinctBy { it.id },
            ),
        ).filter { it.items.isNotEmpty() }
            .map { section -> section.copy(items = section.items.visibleForActiveProfile()) }
            .filter { it.items.isNotEmpty() }
    }.getOrElse { SampleCatalog.homeSections().map { section -> section.copy(items = section.items.visibleForActiveProfile()) } }

    override suspend fun continueWatching(): List<ContinueWatch> =
        WatchStateStore.all()
            // Finished titles stay in History but never in Continue Watching.
            .filter { !it.isWatched && it.progress < 0.9f }
            .map { s ->
            val stored = MediaItem(
                id = s.itemId,
                mediaType = s.mediaType,
                title = s.title.ifBlank { "Title ${s.itemId}" },
                overview = "",
                year = s.year,
                rating = s.rating,
                genreIds = s.genreIds,
                posterPath = s.posterPath,
                backdropPath = s.backdropPath,
            )
            // Hydrate poster/backdrop/rating from TMDB when local state is thin
            // (cloud entries from other devices often miss them).
            val needsHydration = stored.rating <= 0.0 || stored.posterPath == null || stored.backdropPath == null
            val item = if (needsHydration) {
                runCatching { details(s.itemId, s.mediaType) }.getOrNull()?.item
                    ?.let { fresh ->
                        stored.copy(
                            title = stored.title.ifBlank { fresh.title },
                            overview = fresh.overview.ifBlank { stored.overview },
                            year = fresh.year ?: stored.year,
                            rating = if (stored.rating > 0.0) stored.rating else fresh.rating,
                            posterPath = fresh.posterPath ?: stored.posterPath,
                            backdropPath = fresh.backdropPath ?: stored.backdropPath,
                            genres = fresh.genres,
                            genreIds = fresh.genreIds,
                        )
                    } ?: stored
            } else stored
            if (needsHydration && (
                    item.rating != s.rating ||
                        item.posterPath != s.posterPath ||
                        item.backdropPath != s.backdropPath ||
                        item.year != s.year ||
                        (s.title.isBlank() && item.title.isNotBlank())
                    )
            ) {
                WatchStateStore.save(
                    s.copy(
                        title = item.title,
                        year = item.year ?: s.year,
                        rating = item.rating,
                        posterPath = item.posterPath,
                        backdropPath = item.backdropPath,
                    ),
                )
            }
            ContinueWatch(
                item = item,
                progress = s.progress,
                season = s.season,
                episode = s.episode,
            )
        }.filter { !KidsMode.isActive || KidsMode.isKidFriendly(it.item) }

    override suspend fun movies(section: MovieSection, page: Int): List<MediaItem> = runCatching {
        client.genres("movie")
        client.array(section.endpoint, "page" to page.toString()).map(client::parseMedia)
            .visibleForActiveProfile()
    }.getOrElse { SampleCatalog.movies(section, page).visibleForActiveProfile() }

    override suspend fun series(section: SeriesSection, page: Int): List<MediaItem> = runCatching {
        client.genres("tv")
        client.array(section.endpoint, "page" to page.toString()).map(client::parseMedia)
            .visibleForActiveProfile()
    }.getOrElse { SampleCatalog.series(section, page).visibleForActiveProfile() }

    override suspend fun search(query: String, page: Int): List<MediaItem> =
        if (query.isBlank()) emptyList()
        else runCatching {
            client.genres("movie")
            client.genres("tv")
            client.array("/search/multi", "query" to query, "page" to page.toString())
                .filter { it.optString("media_type") == "movie" || it.optString("media_type") == "tv" }
                .map(client::parseMedia)
                .visibleForActiveProfile()
        }.getOrElse { SampleCatalog.search(query, page).visibleForActiveProfile() }

    override suspend fun details(id: String, mediaType: String?): MediaDetails? {
        val type = mediaType ?: resolveType(id)
        return runCatching {
            val raw = when (type) {
                "tv" -> client.json("/tv/$id", "append_to_response" to "credits,videos,seasons,watch/providers")
                else -> client.json("/movie/$id", "append_to_response" to "credits,videos,watch/providers")
            }
            client.genres(type)
            val item = client.parseMedia(raw).copy(mediaType = type)
            client.parseDetails(item, raw)
        }.getOrElse {
            SampleCatalog.details(id, type)
        }
    }

    private suspend fun resolveType(id: String): String {
        // Movie/tv id namespaces don't overlap; probe movie first, then series.
        return runCatching { client.json("/movie/$id"); "movie" }.getOrElse { "tv" }
    }

    override suspend fun recommendations(id: String, mediaType: String?): List<MediaItem> =
        runCatching {
            val type = mediaType ?: resolveType(id)
            val path = if (type == "tv") "/tv/$id/recommendations" else "/movie/$id/recommendations"
            client.genres(type)
            client.array(path).map(client::parseMedia).filter { it.posterUrl != null }
                .visibleForActiveProfile()
        }.getOrElse { emptyList() }

    override suspend fun episodes(seriesId: String, season: Int): List<Episode> = runCatching {
        // Season envelope uses "episodes" (not "results"), so arrayAt is required.
        client.arrayAt("/tv/$seriesId/season/$season", "episodes")
            .map { client.parseEpisode(it, seriesId, season) }
    }.getOrElse { SampleCatalog.episodes(seriesId, season) }

    // ── watchlist ────────────────────────────────────────────────────────────

    override suspend fun watchlist(): List<MediaItem> = CloudSync.watchlist().visibleForActiveProfile()

    override suspend fun isInWatchlist(id: String): Boolean = CloudSync.isInWatchlist(id)

    override suspend fun toggleWatchlist(item: MediaItem) {
        if (CloudSync.isInWatchlist(item.id)) CloudSync.removeFromWatchlist(item)
        else CloudSync.addToWatchlist(item)
    }

    // ── progress ─────────────────────────────────────────────────────────────

    override suspend fun saveProgress(item: MediaItem, season: Int, episode: Int, positionMs: Long, lengthMs: Long) {
        val nearEnd = lengthMs > 0L && positionMs >= lengthMs - 10_000L
        // The player passes a bare MediaItem (id/title/type only). Merge with
        // whatever is already stored so periodic saves can never wipe
        // poster/backdrop/year/rating — which previously forced continueWatching()
        // to re-hydrate every card from TMDB (N+1) on every Home render.
        val existing = WatchStateStore.resumeFor(item.id, season, episode)
        val state = WatchStateStore.WatchState(
            itemId = item.id,
            mediaType = item.mediaType,
            season = season,
            episode = episode,
            positionMs = if (nearEnd) lengthMs else positionMs,
            lengthMs = lengthMs,
            updatedAt = System.currentTimeMillis(),
            title = item.title.ifBlank { existing?.title.orEmpty() },
            posterPath = item.posterPath ?: existing?.posterPath,
            backdropPath = item.backdropPath ?: existing?.backdropPath,
            year = item.year ?: existing?.year,
            rating = item.rating.takeIf { it > 0.0 } ?: existing?.rating ?: 0.0,
            genreIds = item.genreIds.ifEmpty { existing?.genreIds ?: emptyList() },
            // Keep finished titles in history (phone/TV behaviour) and let
            // Continue Watching filter them out instead of deleting the entry
            // on every device.
            isWatched = nearEnd,
        )
        WatchStateStore.save(state)
        if (CloudSync.isSynced) CloudSync.pushWatchHistory(state)
    }
}