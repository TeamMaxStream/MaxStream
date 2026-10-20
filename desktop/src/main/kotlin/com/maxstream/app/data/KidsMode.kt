package com.maxstream.app.data

import com.maxstream.app.data.cloud.ProfileStore
import com.maxstream.app.data.model.MediaItem

/**
 * Kids profile rules shared by every desktop surface. Mirrors the mobile/TV
 * `kids_filter.dart` / `KidsFilter.kt`: animation or family genre means safe.
 * Genre names are used as a fallback for rows whose numeric IDs were not
 * requested (sample catalog, older cached watch-history entries).
 */
object KidsMode {

    const val GENRE_ANIMATION = 16
    const val GENRE_FAMILY = 10751

    /** True while the active profile has the kids flag. Compose-observable. */
    val isActive: Boolean
        get() = ProfileStore.activeProfile?.isKids == true

    fun isKidFriendly(genreIds: List<Int>, genres: List<String> = emptyList()): Boolean {
        if (genreIds.any { it == GENRE_ANIMATION || it == GENRE_FAMILY }) return true
        if (genreIds.isNotEmpty()) return false
        return genres.any {
            it.equals("Animation", ignoreCase = true) ||
                it.equals("Family", ignoreCase = true) ||
                it.equals("Kids", ignoreCase = true)
        }
    }

    fun isKidFriendly(item: MediaItem): Boolean = isKidFriendly(item.genreIds, item.genres)
}

/** Drops non-kid-safe rows for the active profile; no-op otherwise. */
fun List<MediaItem>.visibleForActiveProfile(): List<MediaItem> =
    if (KidsMode.isActive) filter { KidsMode.isKidFriendly(it) } else this
