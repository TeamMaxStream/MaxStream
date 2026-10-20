package com.maxstream.app.data.cloud

import com.maxstream.app.data.WatchStateStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Watch history is shared by the phone, TV, and desktop. These assertions pin
 * the mobile/TV schema (`tmdbId` / `isMovie` / seconds) while making sure the
 * legacy desktop fields stay present for older clients.
 */
class HistoryPayloadTest {

    private fun state(
        mediaType: String = "movie",
        season: Int = 1,
        episode: Int = 1,
        poster: String? = null,
        year: Int? = null,
        isWatched: Boolean = false,
    ) = WatchStateStore.WatchState(
        itemId = "tt42",
        mediaType = mediaType,
        season = season,
        episode = episode,
        positionMs = 5_000L,
        lengthMs = 20_000L,
        updatedAt = 1_700_000_000_000L,
        title = "Some Title",
        posterPath = poster,
        backdropPath = "/bd.jpg",
        year = year,
        rating = 8.2,
        isWatched = isWatched,
    )

    @Test
    fun payloadUsesMobileTvSchema() {
        val payload = CloudSync.historyPayload(state(mediaType = "tv", season = 2, episode = 7))
        assertEquals("tt42", payload.getString("tmdbId"))
        assertFalse(payload.getBoolean("isMovie"))
        assertEquals("Some Title", payload.getString("seriesTitle"))
        assertEquals(5L, payload.getLong("position"))
        assertEquals(20L, payload.getLong("duration"))
        assertEquals(25.0, payload.getDouble("watchPercentage"), 1e-6)
        assertEquals(1_700_000_000_000L, payload.getLong("timestamp"))
        assertFalse(payload.getBoolean("isWatched"))
    }

    @Test
    fun completedEntryCarriesIsWatchedTrue() {
        val payload = CloudSync.historyPayload(state(isWatched = true))
        assertTrue(payload.getBoolean("isWatched"))
        assertEquals(100.0, payload.getDouble("watchPercentage"), 1e-6)
    }

    @Test
    fun payloadKeepsLegacyProgressFields() {
        val payload = CloudSync.historyPayload(state(mediaType = "tv", season = 2, episode = 7))
        assertEquals("tt42", payload.getString("itemId"))
        assertEquals("tv", payload.getString("mediaType"))
        assertEquals(2, payload.getInt("season"))
        assertEquals(7, payload.getInt("episode"))
        assertEquals(5_000L, payload.getLong("positionMs"))
        assertEquals(20_000L, payload.getLong("lengthMs"))
        assertEquals(0.25, payload.getDouble("progress"), 1e-6)
        assertEquals("Some Title", payload.getString("title"))
        assertEquals(8.2, payload.getDouble("rating"), 1e-6)
    }

    @Test
    fun optionalMetadataNeverWritesJsonNull() {
        val payload = CloudSync.historyPayload(state(poster = null, year = null))
        assertEquals("", payload.getString("posterPath"))
        assertEquals("", payload.getString("posterUrl"))
        assertEquals(0, payload.getInt("year"))
        assertFalse(payload.isNull("posterPath"))
        assertFalse(payload.isNull("year"))
    }

    @Test
    fun historyKeyMatchesMobileConvention() {
        assertEquals("movie_tt42", CloudSync.historyKey(state(mediaType = "movie")))
        assertEquals("tv_tt42_2_7", CloudSync.historyKey(state(mediaType = "tv", season = 2, episode = 7)))
    }
}
