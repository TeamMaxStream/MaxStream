# MaxStream Cloudflare Worker - Stream Extractor

This worker extracts `.m3u8` stream URLs server-side, eliminating the need for iframes and popup ads.

## Setup (one-time)

### 1. Create a free Cloudflare account
Go to https://dash.cloudflare.com/sign-up and create an account (no credit card needed).

### 2. Install Wrangler CLI
```bash
npm install -g wrangler
```

### 3. Login to Cloudflare
```bash
wrangler login
```

### 4. Configure the signed media proxy
The browser cannot attach provider Referer/Origin headers directly. Set a
private signing key so the Worker can safely proxy playlists, segments, and
encryption keys:

```bash
cd cloudflare-worker
openssl rand -hex 32 | wrangler secret put PROXY_SECRET
```

Do not add this value to `wrangler.toml` or commit it.

### 5. Update the worker URL in your Flutter app
Edit `lib/services/web_stream_service.dart` and replace the `_workerUrl`:
```dart
static const String _workerUrl = 'https://maxstream-extractor.YOUR_SUBDOMAIN.workers.dev';
```

## Deploy

```bash
cd cloudflare-worker
wrangler deploy
```

That's it! The worker will be available at:
`https://maxstream-extractor.YOUR_SUBDOMAIN.workers.dev`

## How It Works

1. Flutter web app calls `/api/extract?tmdb_id=123&is_movie=true`
2. Worker fetches embed sites (vidlink.pro, etc.) server-side
3. Worker extracts the actual `.m3u8` URL from the HTML
4. Worker returns a signed media-proxy URL to the app
5. The proxy forwards required headers and rewrites nested playlists, segments,
   and encryption-key URLs with browser-compatible CORS headers
6. The app plays the proxied stream using hls.js (no iframe or popup ads)

## API Endpoints

### GET /api/extract
Extract a stream URL.
- `tmdb_id` (required): TMDB ID of the movie/series
- `is_movie` (required): "true" for movie, "false" for series
- `season` (optional): Season number (default: 1)
- `episode` (optional): Episode number (default: 1)

Response:
```json
{
  "url": "https://example.com/video.m3u8",
  "source": "VidLink",
  "type": "hls"
}
```

### GET /api/sources
List available embed sources.

### GET /
Health check.

## Free Tier Limits
- 100,000 requests/day
- 10ms CPU time per request
- No credit card required
- Global edge deployment (300+ locations)
