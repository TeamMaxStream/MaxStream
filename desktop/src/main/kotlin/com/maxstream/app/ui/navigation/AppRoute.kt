package com.maxstream.app.ui.navigation

import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.MovieSection
import com.maxstream.app.data.repository.SeriesSection

/** Screens in the desktop shell. Detail is opened inline (overlays the Home
 *  content, with a back button) rather than pushed on a remote-driven stack —
 *  this is a pointer-app, so navigation stays lightweight and click-based. */
sealed interface AppRoute {
    data object Home : AppRoute
    data class Movies(val initialSection: MovieSection = MovieSection.POPULAR) : AppRoute
    data class Series(val initialSection: SeriesSection = SeriesSection.POPULAR) : AppRoute
    data object Watchlist : AppRoute
    data object Downloads : AppRoute
    data object History : AppRoute
    data object Settings : AppRoute
    data class Detail(val itemId: String, val mediaType: String? = null, val key: String = itemId) : AppRoute
    data class Player(val request: PlayRequest, val key: String = "${request.itemId}-${request.season}-${request.episode}") : AppRoute
}