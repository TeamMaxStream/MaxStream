package com.maxstream.app.ui.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.viewModelScope
import android.annotation.SuppressLint
import com.maxstream.app.data.local.WatchProgressRepository
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.repository.CloudSyncRepository
import com.maxstream.app.di.Modules
import com.maxstream.app.util.isKidFriendly
import com.maxstream.app.util.isKidsProfile
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

class HomeViewModel(application: Application) : AndroidViewModel(application) {
    private val repo = Modules.catalogRepository

    private val _trendingMovies = MutableLiveData<List<MediaItem>>(emptyList())
    private val _trendingSeries = MutableLiveData<List<MediaItem>>(emptyList())
    private val _popularMovies = MutableLiveData<List<MediaItem>>(emptyList())
    private val _popularSeries = MutableLiveData<List<MediaItem>>(emptyList())
    private val _topRatedMovies = MutableLiveData<List<MediaItem>>(emptyList())
    private val _topRatedSeries = MutableLiveData<List<MediaItem>>(emptyList())
    private val _continueWatching = MutableLiveData<List<MediaItem>>(emptyList())
    private val _forYou = MutableLiveData<List<MediaItem>>(emptyList())
    private val _becauseYouWatched = MutableLiveData<Pair<String, List<MediaItem>>>(null)
    private val _comingSoon = MutableLiveData<List<MediaItem>>(emptyList())
    private val _loading = MutableLiveData(true)
    private val _error = MutableLiveData<String?>(null)

    /** Filter list to kid-friendly content when active profile is kids. */
    private fun filterKids(items: List<MediaItem>): List<MediaItem> {
        if (!isKidsProfile(getApplication())) return items
        return items.filter { isKidFriendly(it.genreIds) }
    }

    val trendingMovies: LiveData<List<MediaItem>> = _trendingMovies
    val trendingSeries: LiveData<List<MediaItem>> = _trendingSeries
    val popularMovies: LiveData<List<MediaItem>> = _popularMovies
    val popularSeries: LiveData<List<MediaItem>> = _popularSeries
    val topRatedMovies: LiveData<List<MediaItem>> = _topRatedMovies
    val topRatedSeries: LiveData<List<MediaItem>> = _topRatedSeries
    val continueWatching: LiveData<List<MediaItem>> = _continueWatching
    val forYou: LiveData<List<MediaItem>> = _forYou
    val becauseYouWatched: LiveData<Pair<String, List<MediaItem>>> = _becauseYouWatched
    val comingSoon: LiveData<List<MediaItem>> = _comingSoon
    val loading: LiveData<Boolean> = _loading
    val error: LiveData<String?> = _error

    init {
        loadAll()
    }

    @SuppressLint("NullSafeMutableLiveData")
    fun loadAll() {
        _loading.value = true
        _error.value = null
        viewModelScope.launch {
            try { CloudSyncRepository.pullToDevice(getApplication()) } catch (_: Exception) {}

            val trendingMoviesDef = async { runCatching { repo.trendingMovies() }.getOrNull() ?: emptyList() }
            val trendingSeriesDef = async { runCatching { repo.trendingSeries() }.getOrNull() ?: emptyList() }
            val popularMoviesDef = async { runCatching { repo.popularMovies() }.getOrNull() ?: emptyList() }
            val popularSeriesDef = async { runCatching { repo.popularSeries() }.getOrNull() ?: emptyList() }
            val topRatedMoviesDef = async { runCatching { repo.topRatedMovies() }.getOrNull() ?: emptyList() }
            val topRatedSeriesDef = async { runCatching { repo.topRatedSeries() }.getOrNull() ?: emptyList() }
            val comingSoonDef = async {
                val movies = runCatching { repo.upcomingMovies() }.getOrNull() ?: emptyList()
                val series = runCatching { repo.onTheAirSeries() }.getOrNull() ?: emptyList()
                (movies + series).sortedByDescending { it.releaseDate }.take(15)
            }
            try {
                _trendingMovies.value = filterKids(trendingMoviesDef.await())
                _trendingSeries.value = filterKids(trendingSeriesDef.await())
                _popularMovies.value = filterKids(popularMoviesDef.await())
                _popularSeries.value = filterKids(popularSeriesDef.await())
                _topRatedMovies.value = filterKids(topRatedMoviesDef.await())
                _topRatedSeries.value = filterKids(topRatedSeriesDef.await())
                _comingSoon.value = filterKids(comingSoonDef.await())
            } catch (e: Exception) {
                _error.value = e.message
            }

            _continueWatching.value = runCatching {
                continueWatchingItems()
            }.getOrDefault(emptyList())

            // Personalized recommendations based on watch history
            loadPersonalizedRecommendations()

            _loading.value = false
            if (_trendingMovies.value.isNullOrEmpty() && _trendingSeries.value.isNullOrEmpty() &&
                _popularMovies.value.isNullOrEmpty() && _topRatedMovies.value.isNullOrEmpty()
            ) {
                _error.value = _error.value ?: "No content available. Pull to refresh or check connection."
            }
        }
    }

    private suspend fun loadPersonalizedRecommendations() {
        val history = WatchProgressRepository.recent(getApplication(), limit = 50)
        if (history.isEmpty()) {
            // No history: show trending as "For You" fallback
            val fallback = _trendingMovies.value.orEmpty().shuffled().take(10) +
                _trendingSeries.value.orEmpty().shuffled().take(10)
            _forYou.value = fallback.shuffled().take(15)
            return
        }

        // Calculate top genres from watch history (same algorithm as Dart RecommendationService)
        val genreWeights = mutableMapOf<Int, Double>()
        val seen = mutableSetOf<String>()
        for (entry in history) {
            val key = "${entry.tmdbId}:${entry.isMovie}"
            if (key in seen) continue
            seen.add(key)

            val weight = when {
                entry.isWatched -> 2.0
                entry.progress > 0.5f -> 1.5
                else -> 1.0
            }

            // Fetch genre IDs from TMDB details for this item
            val genreIds = try {
                val details = if (entry.isMovie) {
                    repo.movieDetails(entry.tmdbId.toIntOrNull() ?: 0)
                } else {
                    repo.seriesDetails(entry.tmdbId.toIntOrNull() ?: 0)
                }
                val genres = details.optJSONArray("genres") ?: org.json.JSONArray()
                (0 until genres.length()).mapNotNull { genres.optJSONObject(it)?.optInt("id") }
            } catch (_: Exception) {
                emptyList()
            }

            for (gid in genreIds) {
                genreWeights[gid] = (genreWeights[gid] ?: 0.0) + weight
            }
        }

        val topGenres = genreWeights.entries.sortedByDescending { it.value }.take(3).map { it.key }
        if (topGenres.isEmpty()) {
            _forYou.value = _trendingMovies.value.orEmpty().shuffled().take(15)
            return
        }

        // "For You" — content from top genres
        val forYouItems = mutableListOf<MediaItem>()
        for (gid in topGenres.take(2)) {
            val items = runCatching { repo.catalogByGenre(gid, "movie") }.getOrNull()?.take(5) ?: emptyList()
            forYouItems.addAll(filterKids(items))
            val tvItems = runCatching { repo.catalogByGenre(gid, "tv") }.getOrNull()?.take(5) ?: emptyList()
            forYouItems.addAll(filterKids(tvItems))
        }
        _forYou.value = forYouItems.shuffled().take(15)

        // "Because You Watched {title}" — TMDB recommendations for most recent watch
        val mostRecent = history.first()
        val recentId = mostRecent.tmdbId.toIntOrNull() ?: return
        val recs = try {
            if (mostRecent.isMovie) repo.movieRecommendations(recentId)
            else repo.seriesRecommendations(recentId)
        } catch (_: Exception) {
            emptyList()
        }
        if (recs.isNotEmpty()) {
            _becauseYouWatched.value = mostRecent.displayTitle to filterKids(recs).take(15)
        }
    }

    @SuppressLint("NullSafeMutableLiveData")
    fun refreshSynced() {
        _continueWatching.value = continueWatchingItems()
    }

    // Filter BEFORE limiting: taking the 20 newest entries first let finished
    // episodes fill every slot and hid older unfinished titles.
    private fun continueWatchingItems(): List<MediaItem> = WatchProgressRepository
        .history(getApplication())
        .filter { entry -> entry.isVisibleInContinueWatching() }
        .take(20)
        .map { it.toMediaItem() }
}
