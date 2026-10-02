# MaxStream

A Flutter streaming app for movies and TV series with native Kotlin stream extraction, multi-provider fallback, and smooth HLS playback.

<div align="center">
  <img src="assets/images/maxstream_logo.png" alt="MaxStream Logo" width="128" height="128" />
</div>

## Screenshots

<table align="center">
  <tr>
    <td align="center"><img src="Images/Home_Screen.jpg" alt="Home" width="220" /><br/><sub>Home</sub></td>
    <td align="center"><img src="Images/Search_Screen1.jpg" alt="Search" width="220" /><br/><sub>Search</sub></td>
    <td align="center"><img src="Images/Watchlist_Screen.jpg" alt="Watchlist" width="220" /><br/><sub>Watchlist</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="Images/Login-Signup_Screen.jpg" alt="Login" width="220" /><br/><sub>Login</sub></td>
    <td align="center"><img src="Images/Search_Screen2.jpg" alt="Search Results" width="220" /><br/><sub>Search Results</sub></td>
    <td align="center"><img src="Images/More_Screen.jpg" alt="More" width="220" /><br/><sub>More</sub></td>
  </tr>
</table>

## Features

- **Native Stream Extraction** — Kotlin-powered extraction using OkHttp with DNS-over-HTTPS, parallel server discovery, and HLS validation
- **Multi-Provider Fallback** — 20+ stream sources tried automatically: VidLink, VixSrc, Vidrock, Vidzee, Videasy, PrimeSrc, Frembed, RPM, VidsrcNet, VidsrcRu, VidsrcTo, Moviesapi, 2Embed, Vidflix, VOE, Streamtape, and more
- **Smooth HLS Playback** — Parallel variant validation, ExoPlayer with 30s back buffer, adaptive quality switching
- **Subtitle Support** — Grouped by source server (VidLink, RPM, Vidsrc, HLS), SRT/VTT parsing, inline display
- **Quality Selection** — Manual quality picker with auto-switching support
- **Episode Autoplay** — Auto-advances to next episode with 30s countdown
- **Watch History** — Resume playback from last position, saved every 15 seconds
- **Watchlist** — Save favorite content for later
- **Firebase Auth** — Email/password and Google Sign-In
- **TMDB Integration** — Movie/series metadata, posters, backdrops, episode info
- **TV Mode** — Dedicated Android TV interface with D-pad navigation
- **Auto-Update** — Checks GitHub Releases for new versions, shows changelog, downloads and installs APK
- **Push Notifications** — Content availability alerts via Firebase

## Architecture

### Stream Extraction Pipeline

```
User selects content
    ↓
DirectM3u8Service.fetchMovieStreamUrl() / fetchSeriesStreamUrl()
    ↓
NativeStreamExtractor.resolveStream()  [Platform Channel]
    ↓
StreamExtractor.resolveStream()  [Kotlin, OkHttp]
    ↓
┌─────────────────────────────────────────┐
│  Server Providers (parallel discovery)  │
│  StaticTmdbProvider, VidrockProvider,   │
│  VidzeeProvider, PrimeSrcProvider,      │
│  FrembedProvider                        │
└─────────────────────────────────────────┘
    ↓  (20+ servers per movie)
┌─────────────────────────────────────────┐
│  Host Extractors (per-URL matching)     │
│  VidLink (WebView), RPM (AES-CBC),     │
│  VixSrc (signed URLs), VidsrcNet       │
│  (10 decryption algos), Vidrock,       │
│  Vidzee (AES-GCM), VOE, GenericMedia   │
└─────────────────────────────────────────┘
    ↓
Parallel HLS Validation (coroutineScope + async)
    ↓
video_player + Chewie (ExoPlayer on Android)
    ↓
Video plays with subtitles, quality switching, episode autoplay
```

### How Stream Extraction Works

1. **Server Discovery** — Multiple `ServerProvider`s run in parallel, each generating server URLs from TMDB IDs
2. **Extractor Dispatch** — Each server URL is matched to a `HostExtractor` by domain
3. **Stream Resolution** — Extractors resolve embed pages, decrypt payloads, follow redirects
4. **Redirect Chaining** — Up to 5 redirect hops with cycle detection
5. **HLS Validation** — Master playlist parsed, variants validated in parallel, subtitles extracted
6. **Playback** — URL handed to ExoPlayer with headers, back buffer configured

### Key Extractors

| Extractor | Technique |
|-----------|-----------|
| **VidLink** | WebView JS injection intercepts `/api/b/` fetch responses |
| **RPM** | AES-CBC decryption of hex payload, 5 route candidates (HLS, TikTok, Cloudflare) |
| **VixSrc** | Signed URL construction with token expiry, 410 retry |
| **VidsrcNet** | 3-level iframe chain, 10 per-ID decryption algorithms (XOR, Base64, ROT13) |
| **Vidrock** | AES-encrypted TMDB ID, tries all servers from API response |
| **Vidzee** | AES-GCM master key from remote API, AES-CBC link decryption |
| **VidsrcRu** | WebView network interception of `/file2/*.m3u8` URLs |
| **VidsrcTo** | RC4 decryption with GitHub-hosted keys, multi-source fallback |
| **Frembed** | API-based server list with HTTP redirect resolution |
| **GenericMedia** | Catch-all regex scan for `.m3u8`/`.mp4` URLs in page HTML |

## Tech Stack

- **Framework**: Flutter 3.8.0+ (Dart)
- **Native**: Kotlin (Android) — stream extraction, HLS validation
- **Video**: video_player + Chewie (ExoPlayer on Android)
- **HTTP**: OkHttp with DNS-over-HTTPS (Google DNS)
- **Auth**: Firebase Auth (Email/Password, Google Sign-In)
- **Database**: Firebase Firestore + SQLite (local)
- **API**: TMDB API (movie/series metadata)
- **State**: Provider
- **UI**: Material Design, Glassmorphism, Shimmer, Lottie

## Project Structure

```
lib/
├── main.dart / main_phone.dart     # App entry points
├── screens/                         # UI screens
│   ├── m3u8_video_player_screen.dart  # Main video player with subtitles, quality, autoplay
│   ├── maxstream_main_screen.dart     # Bottom nav (Home, Search, Series, Watchlist, More)
│   ├── maxstream_home_screen.dart     # Home with hero banners, sliders
│   ├── maxstream_search_screen.dart   # Search with All/Movies/TV/Actors tabs
│   ├── maxstream_details_screen.dart  # Movie/series detail pages
│   ├── maxstream_series_list_screen.dart
│   ├── maxstream_watchlist_screen.dart
│   ├── profile_settings_screen.dart   # Profile, name, picture, password
│   └── streaming_provider_settings_screen.dart
├── services/
│   ├── native_stream_extractor.dart   # Platform channel bridge to Kotlin
│   ├── direct_m3u8_service.dart       # Stream URL resolution service
│   ├── tmdb_api_service.dart          # TMDB API client
│   ├── profile_service.dart           # Firebase profile picture upload
│   ├── watch_history_service.dart     # SQLite watch history
│   ├── update_service.dart            # GitHub Releases auto-updater
│   ├── notification_service.dart      # Local notifications
│   ├── auth_service.dart              # Firebase authentication
│   └── user_service.dart              # User profile management
├── tv/                               # Android TV interface
│   ├── screens/                       # TV-optimized screens
│   ├── widgets/                       # TV focus, navigation, keyboard
│   ├── services/                      # TV scraper service
│   └── providers/                     # TV state management
├── widgets/                          # Reusable UI components
├── models/                           # Data models (Movie, Series)
├── database/                         # SQLite helpers
├── config/                           # API configuration
└── utils/                            # Utilities, responsive helpers

android/app/src/main/kotlin/com/maxstream/app/
├── MainActivity.kt                   # Platform channel handler
└── StreamExtractor.kt                # ~1500 lines: 4 server providers, 17 host extractors, HLS validation
```

## Getting Started

### Prerequisites

- Flutter SDK >=3.8.0
- Firebase project with Auth enabled
- TMDB API key

### Installation

```bash
git clone https://github.com/TeamMaxStream/MaxStream.git
cd maxstream
flutter pub get
flutter run
```

### Configuration

1. **Firebase** — Create project, enable Auth, download `google-services.json` to `android/app/`
2. **TMDB** — Get API key from [themoviedb.org](https://www.themoviedb.org/settings/api), add to `lib/config/api_config.dart`

## Auto-Update System

The app checks GitHub Releases on startup for newer versions:

1. Hits `https://api.github.com/repos/TeamMaxStream/MaxStream/releases/latest`
2. Compares release tag (e.g. `v1.0.1`) with installed version
3. Shows local notification + in-app dialog with changelog from release body
4. Downloads `MaxStream.apk` from the release asset
5. Prompts Android package installer

To release an update:
1. Build APK: `flutter build apk --release`
2. Create GitHub release with tag `v1.0.1`, title `v1.0.1`
3. Attach `MaxStream.apk` as a release asset
4. Write changelog in the release body

## Build

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release
```

## Version

- **Current**: 1.5.0+7
- **Min SDK**: 3.8.0

## Contributing

Pull requests welcome. For major changes, open an issue first.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**TeamMaxStream** — [github.com/TeamMaxStream/MaxStream](https://github.com/TeamMaxStream/MaxStream)
