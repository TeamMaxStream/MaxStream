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
- **Auto-Update** — One GitHub release updates the phone, TV, and desktop apps
- **Push Notifications** — Content availability alerts via Firebase

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

The phone, TV, and desktop apps share one product version and one GitHub
release. Each app checks `TeamMaxStream/MaxStream` for a newer tag and updates
itself from that release:

1. Reads `TeamMaxStream/MaxStream` releases (phone/TV use `/releases/latest`,
   desktop scans recent releases for an installer asset)
2. Compares the release tag (e.g. `v1.7.1`) with the installed version
3. Shows the changelog from the release body
4. Downloads the matching asset:
   - phone: `maxstream-<abi>.apk` for the device CPU
   - TV: `maxstream-tv.apk`
   - desktop: `MaxStream-Dex.exe` or `MaxStream-Desktop.msi`
5. Installs it (Android package installer / Windows installer)

Releases are built and published by `.github/workflows/build.yml`. Push a tag,
do not create the release by hand:

1. Bump the version in all four places:
   - `pubspec.yaml`
   - `android/tvapp/build.gradle.kts` (`versionName`, `versionCode`)
   - `desktop/build.gradle.kts` (`version` and `packageVersion`)
   - `desktop/src/main/kotlin/com/maxstream/app/core/AppConfig.kt`
2. Commit, then push a tag such as `v1.7.1`
3. CI builds the phone APKs, TV APK, desktop EXE/MSI, verifies every version
   matches the tag, and attaches all assets to one release

## Build

```bash
# Android APK / App Bundle
flutter build apk --release
flutter build appbundle --release

# Android TV APK
cd android && ./gradlew assembleFossUniversalRelease

# Desktop (Windows installer + portable app image)
cd desktop
./gradlew packageReleaseMsi
./gradlew packageReleaseExe
```

## Version

- **Current**: 1.8.0 (mobile `1.8.0+10`)
- **Min SDK**: 3.8.0

## Contributing

Pull requests welcome. For major changes, open an issue first.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**TeamMaxStream** — [github.com/TeamMaxStream/MaxStream](https://github.com/TeamMaxStream/MaxStream)
