package com.maxstream.app.ui.navigation

sealed class Screen(val route: String) {
    // ── Auth / pre-shell ────────────────────────────────────────────────────
    data object Splash  : Screen("splash")
    data object Login   : Screen("login")
    data object ProfileSelect : Screen("profile_select")

    // ── Main shell (IndexedStack lives here) ────────────────────────────────
    data object Shell   : Screen("shell")

    // ── Deep-nav overlays (push on top of shell) ───────────────────────────
    /** Invisible placeholder that stays at the bottom of the deep-nav stack so
     * popping Details/Player never empties it. The shell below is only ever
     * composed inside its own (underlay) NavHost, so tab focus/scroll state
     * survives every details/player excursion. */
    data object DeepRoot : Screen("deep_root")

    data object Details : Screen("details/{itemId}/{mediaType}") {
        fun createRoute(itemId: String, mediaType: String = "movie") = "details/$itemId/$mediaType"
    }
    data object Player : Screen("player/{itemId}/{mediaType}?season={season}&episode={episode}") {
        fun createRoute(
            itemId: String,
            mediaType: String,
            season: Int = 1,
            episode: Int = 1,
        ) = "player/$itemId/$mediaType?season=$season&episode=$episode"
    }

    /** Full list behind a row's trailing `>` "See All" cell (Home rows and
     *  the Series List rows both land here). `kind` is a MoreContentKind name. */
    data object MoreContent : Screen("more_content/{kind}") {
        fun createRoute(kind: String) = "more_content/$kind"
    }

    // ── Sidebar tab indices (not routes — kept here for readability) ─────────
    //  0 = Home  1 = Search  2 = Genre  3 = Series list  4 = Watchlist  5 = More
}
