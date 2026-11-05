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
- **Passwordless TV Pairing** — A one-time 6-digit code pairs a TV; no password is ever stored or sent
- **TMDB Integration** — Movie/series metadata, posters, backdrops, episode info
- **TV Mode** — Dedicated Android TV interface with D-pad navigation
- **Verified Auto-Update** — One GitHub release updates the phone, TV, and desktop apps; every download is checked against the release's `SHA256SUMS`
- **Push Notifications** — Content availability alerts via Firebase

## Tech Stack

- **Framework**: Flutter 3.8.0+ (Dart)
- **Native**: Kotlin (Android) — stream extraction, HLS validation
- **Video**: video_player + Chewie (ExoPlayer on Android)
- **HTTP**: OkHttp with DNS-over-HTTPS (Google DNS)
- **Auth**: Firebase Auth (Email/Password, Google Sign-In), Firebase custom tokens for TV pairing
- **Database**: Firebase Realtime Database + SQLite (local)
- **API**: TMDB API (movie/series metadata)
- **UI**: Material Design, Glassmorphism, Shimmer, Lottie

## Getting Started

### Prerequisites

- Flutter SDK >=3.8.0
- Firebase project with Auth and Realtime Database enabled
- TMDB API key

> iOS is not a supported target. The stream extractor, installer, update checker,
> and TV pairing native channels are Android-only; the `ios/` folder is only the
> Flutter scaffold.

### Installation

```bash
git clone https://github.com/TeamMaxStream/MaxStream.git
cd maxstream
flutter pub get
flutter run
```

### Configuration

API keys are injected at build time and are never committed.

1. **Firebase** — Create the project, enable Auth and Realtime Database, and
   download `google-services.json` into `android/app/`.

2. **TMDB** — Get a v3 API key from
   [themoviedb.org](https://www.themoviedb.org/settings/api). Pass it to each
   build:

   ```bash
   # Phone (Flutter)
   flutter run --dart-define=TMDB_API_KEY=your-key

   # Or keep local values in config/secrets.json (git-ignored) and use:
   flutter run --dart-define-from-file=config/secrets.json

   # Android TV
   cd android && ./gradlew assembleFossUniversalRelease -PTMDB_API_KEY=your-key

   # Desktop
   cd desktop && ./gradlew packageReleaseMsi -PTMDB_API_KEY=your-key
   ```

   `TMDB_API_KEY` is also read from the environment. Copy
   `config/secrets.example.json` to `config/secrets.json` for the
   `--dart-define-from-file` flow. CI reads the `TMDB_API_KEY` repository
   secret, and Vercel reads its `TMDB_API_KEY` environment variable.

## TV Pairing

Pairing never sends or stores a password:

1. The signed-in phone writes `{code, userId, createdAt, expiresAt, isUsed:false}`
   to RTDB `device_codes/<code>`. The rules allow only the owning user to create
   one and deny all client reads.
2. The TV sends the 6-digit code to the pairing Worker
   (`POST /pairing/redeem`). The Worker validates it, burns it with an ETag-
   conditional write, and returns a Firebase custom token.
3. The TV exchanges that token for a session. Codes are single-use, expire after
   15 minutes, and are bound to the phone user's uid.

The Worker lives in `worker/pairing/`; see its
[README](worker/pairing/README.md) for deployment, rate limiting, rotating the
service account, and the one-time purge of legacy password-bearing codes. After
the tightened `database.rules.json` is deployed, app builds older than 1.8.0 can
no longer create or read pairing codes and must update.

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
5. Verifies the download against the release's `SHA256SUMS` before installing
   (fails closed: a missing sidecar, missing entry, or mismatch aborts the
   update and deletes the file)
6. Installs it (Android package installer / Windows installer)

Releases are built and published by `.github/workflows/build.yml`. Push a tag,
do not create the release by hand:

1. Bump the version in all four places:
   - `pubspec.yaml`
   - `android/tvapp/build.gradle.kts` (`versionName`, `versionCode`)
   - `desktop/build.gradle.kts` (`version` and `packageVersion`)
   - `desktop/src/main/kotlin/com/maxstream/app/core/AppConfig.kt`
2. Commit, then push a tag such as `v1.7.1`
3. CI builds the phone APKs, TV APK, desktop EXE/MSI, verifies every version
   matches the tag, generates `SHA256SUMS`, and attaches all assets to one
   release

## Build

```bash
# Android APK / App Bundle
flutter build apk --release --dart-define=TMDB_API_KEY=your-key
flutter build appbundle --release --dart-define=TMDB_API_KEY=your-key

# Android TV APK
cd android && ./gradlew assembleFossUniversalRelease -PTMDB_API_KEY=your-key

# Desktop (Windows installer + portable app image)
cd desktop
./gradlew packageReleaseMsi -PTMDB_API_KEY=your-key
./gradlew packageReleaseExe -PTMDB_API_KEY=your-key
```

## Project layout

- `lib/` — Flutter phone app; the player is split into `lib/screens/player/`
- `android/app/` — Android host (`com.maxstream.app`), installer/arch channels
- `android/streamcore/` — shared Kotlin stream extractor used by the phone and TV
- `android/tvapp/` — Android TV client (Compose)
- `desktop/` — JVM/Compose desktop client. It keeps its own copy of
  `StreamExtractor.kt` because `:streamcore` is an Android library that cannot be
  linked into a plain JVM build; extractor fixes must be mirrored there.
- `worker/pairing/` — Cloudflare Worker that exchanges pairing codes for custom
  tokens

## Version

- **Current**: 1.8.0 (mobile `1.8.0+10`)
- **Minimum Flutter**: 3.8.0

## Contributing

Pull requests welcome. For major changes, open an issue first.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**TeamMaxStream** — [github.com/TeamMaxStream/MaxStream](https://github.com/TeamMaxStream/MaxStream)
