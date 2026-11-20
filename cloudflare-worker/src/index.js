/// Cloudflare Worker: MaxStream Stream Extractor
/// Extracts stream URLs server-side via HTTP requests and regex parsing.
/// No iframes, no popups, no ads.

import { secretbox } from "./secretbox.js";

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const TOKEN_TTL_SECONDS = 6 * 60 * 60;
const MAX_REDIRECTS = 5;
const MAX_PLAYLIST_BYTES = 2 * 1024 * 1024;

const VIDLINK_BASE = "https://vidlink.pro";
const VIDLINK_API_KEY = "c75136c5668bbfe65a7ecad431a745db68b5f381555b38d8f6c699449cf11fcd";
const NETMIRROR_BASE = "https://net79.cc";

export default {
  async fetch(request, env) {
    const corsHeaders = {
      "Access-Control-Allow-Origin": env.CORS_ORIGIN || "*",
      "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Range, If-Range",
      "Access-Control-Expose-Headers":
        "Content-Length, Content-Range, Accept-Ranges, ETag, Last-Modified",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    const url = new URL(request.url);

    if (url.pathname === "/") {
      return new Response(
        JSON.stringify({ status: "ok", service: "maxstream-extractor" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Served raw by GitHub Pages, so the website's /status page fetches it
    // cross-origin from the browser: CORS must be on this response too.
    if (url.pathname === "/health") {
      return this.handleHealth(url, corsHeaders, env);
    }

    if (url.pathname === "/api/extract") {
      return this.handleExtract(url, corsHeaders, env, url.origin);
    }

    if (url.pathname === "/api/media") {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return this.jsonError("Method not allowed", 405, corsHeaders);
      }
      return this.handleMedia(request, url, corsHeaders, env);
    }

    return new Response(JSON.stringify({ error: "Not found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  },

  async handleExtract(url, corsHeaders, env, workerOrigin) {
    if (!env.PROXY_SECRET) {
      return this.jsonError("Media proxy is not configured", 503, corsHeaders);
    }
    const tmdbId = url.searchParams.get("tmdb_id") || url.searchParams.get("tmdb");
    const typeParam = (url.searchParams.get("type") || "").toLowerCase();
    const isMovie = typeParam
      ? typeParam === "movie"
      : url.searchParams.get("is_movie") === "true";
    const season = parseInt(url.searchParams.get("season") || "1", 10) || 1;
    const episode = parseInt(url.searchParams.get("episode") || "1", 10) || 1;
    const server = (url.searchParams.get("server") || "").toLowerCase();

    if (!tmdbId) {
      return new Response(JSON.stringify({ error: "tmdb_id required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    console.log(`Extract: TMDB ${tmdbId} movie=${isMovie} s${season}e${episode} server=${server || "all"}`);

    const extractors = {
      netmirror: () => this.extractNetMirror(tmdbId, isMovie, season, episode),
      vixsrc: () => this.extractVixSrc(tmdbId, isMovie, season, episode),
      vidlink: () => this.extractVidLink(tmdbId, isMovie, season, episode),
      "2embed": () => this.extract2Embed(tmdbId, isMovie, season, episode),
      goodstream: () => this.extractGoodstream(tmdbId, isMovie, season, episode),
    };

    // If a specific server was requested, only try that one.
    if (server) {
      if (!extractors[server]) {
        return this.jsonError(`Unknown server: ${server}`, 400, corsHeaders);
      }
      try {
        const result = await extractors[server]();
        if (result) {
          console.log(`${server} success: ${result.url}`);
          const publicResult = await this.createPublicResult(result, env, workerOrigin);
          return new Response(JSON.stringify(publicResult), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      } catch (e) {
        console.log(`${server} failed: ${e.message}`);
      }
      return new Response(JSON.stringify({ error: `${server} failed` }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Try all servers in order.
    for (const id of ["netmirror", "vixsrc", "vidlink", "goodstream", "2embed"]) {
      try {
        const result = await extractors[id]();
        if (result) {
          console.log(`${id} success: ${result.url}`);
          const publicResult = await this.createPublicResult(result, env, workerOrigin);
          return new Response(JSON.stringify(publicResult), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      } catch (e) {
        console.log(`${id} failed: ${e.message}`);
      }
    }

    return new Response(JSON.stringify({ error: "No stream found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  },

  async createPublicResult(result, env, workerOrigin) {
    if (!env.PROXY_SECRET) throw new Error("PROXY_SECRET is not configured");
    this.validateUpstreamUrl(result.url);
    const profile = this.profileForResult(result);
    const type = result.type === "hls" ? "hls" : result.type === "dash" ? "dash" : "direct";
    // HLS manifests get rewritten; direct MP4/DASH is streamed through the same
    // signed proxy with Range passthrough (NetMirror and VidLink both serve MP4).
    const kind = type === "hls" ? "playlist" : "segment";
    const url = await this.createMediaUrl(workerOrigin, result.url, kind, profile, env.PROXY_SECRET);
    const payload = { url, source: result.source, type };

    if (Array.isArray(result.qualities) && result.qualities.length > 0) {
      const qualityKind = type === "hls" ? "playlist" : "segment";
      payload.qualities = await Promise.all(
        result.qualities.map(async (quality) => ({
          label: quality.label,
          height: quality.height,
          codec: quality.codec,
          url: await this.createMediaUrl(
            workerOrigin,
            quality.url,
            qualityKind,
            profile,
            env.PROXY_SECRET
          ),
        }))
      );
    }
    if (Array.isArray(result.subtitles) && result.subtitles.length > 0) {
      payload.subtitles = result.subtitles;
    }
    return payload;
  },

  profileForResult(result) {
    const source = result.source || "";
    if (source === "NetMirror") return "netmirror";
    if (source === "VixSrc") return "vixsrc";
    if (source === "VidLink") return "vidlink";
    if (source === "2Embed") return "2embed";
    if (source === "Goodstream") return "goodstream";
    throw new Error("Unsupported provider profile");
  },

  profileHeaders(profile, url) {
    const headers = { "User-Agent": USER_AGENT };
    if (profile === "vixsrc") {
      headers.Referer = "https://vixsrc.to/";
      headers.Origin = "https://vixsrc.to";
    } else if (profile === "vidlink") {
      // The hakunaymatata CDN rejects provider Referer/Origin headers.
      if (!(url && url.includes("hakunaymatata.com"))) {
        headers.Referer = "https://vidlink.pro/";
        headers.Origin = "https://vidlink.pro";
      }
    } else if (profile === "netmirror") {
      headers.Referer = `${NETMIRROR_BASE}/`;
    } else if (profile === "2embed") {
      headers.Referer = "https://www.2embed.cc/";
      headers.Origin = "https://www.2embed.cc";
    } else if (profile === "goodstream") {
      headers.Referer = "https://goodstream.one/";
      headers.Origin = "https://goodstream.one";
    } else {
      throw new Error("Invalid provider profile");
    }
    return headers;
  },

  async handleMedia(request, url, corsHeaders, env) {
    if (!env.PROXY_SECRET) {
      return this.jsonError("Media proxy is not configured", 503, corsHeaders);
    }
    try {
      const payload = await this.verifyMediaToken(
        url.searchParams.get("token"),
        url.searchParams.get("sig"),
        env.PROXY_SECRET
      );
      this.validateUpstreamUrl(payload.url);
      const headers = this.profileHeaders(payload.profile, payload.url);
      const range = request.headers.get("Range");
      const ifRange = request.headers.get("If-Range");
      if (range) headers.Range = range;
      if (ifRange) headers["If-Range"] = ifRange;

      const { response, effectiveUrl } = await this.fetchWithRedirects(
        payload.url,
        { method: request.method === "HEAD" ? "HEAD" : "GET", headers }
      );
      if (!response.ok && response.status !== 206 && response.status !== 416) {
        return this.jsonError(`Upstream media error ${response.status}`, 502, corsHeaders);
      }

      if (payload.kind === "playlist" && request.method !== "HEAD") {
        const length = Number(response.headers.get("Content-Length") || "0");
        if (length > MAX_PLAYLIST_BYTES) throw new Error("Playlist is too large");
        const text = await response.text();
        if (text.length > MAX_PLAYLIST_BYTES || !text.trimStart().startsWith("#EXTM3U")) {
          throw new Error("Invalid HLS playlist");
        }
        const rewritten = await this.rewritePlaylist(
          text,
          effectiveUrl,
          payload.profile,
          url.origin,
          env.PROXY_SECRET
        );
        return new Response(rewritten, {
          status: response.status,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/vnd.apple.mpegurl",
            "Cache-Control": "no-store",
          },
        });
      }

      const outputHeaders = { ...corsHeaders };
      for (const name of [
        "Content-Type",
        "Content-Length",
        "Content-Range",
        "Accept-Ranges",
        "ETag",
        "Last-Modified",
      ]) {
        const value = response.headers.get(name);
        if (value) outputHeaders[name] = value;
      }
      outputHeaders["Cache-Control"] = payload.kind === "key" ? "no-store" : "private, max-age=300";
      return new Response(request.method === "HEAD" ? null : response.body, {
        status: response.status,
        headers: outputHeaders,
      });
    } catch (error) {
      console.log(`Media proxy failed: ${error.message}`);
      return this.jsonError("Invalid or unavailable media URL", 403, corsHeaders);
    }
  },

  async rewritePlaylist(text, baseUrl, profile, workerOrigin, secret) {
    if (!baseUrl) throw new Error("Playlist base URL is missing");
    const lines = text.split(/\r?\n/);
    let nextUriIsPlaylist = false;
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      if (line.startsWith("#EXT-X-STREAM-INF:")) {
        nextUriIsPlaylist = true;
        continue;
      }
      if (line && !line.startsWith("#")) {
        const kind = nextUriIsPlaylist ? "playlist" : "segment";
        lines[index] = await this.proxyChildUrl(line.trim(), baseUrl, kind, profile, workerOrigin, secret);
        nextUriIsPlaylist = false;
        continue;
      }
      if (!line.startsWith("#") || !line.includes("URI=")) continue;
      let kind = "segment";
      if (line.startsWith("#EXT-X-KEY:") || line.startsWith("#EXT-X-SESSION-KEY:")) kind = "key";
      else if (line.startsWith("#EXT-X-MAP:")) kind = "map";
      else if (
        line.startsWith("#EXT-X-MEDIA:") ||
        line.startsWith("#EXT-X-I-FRAME-STREAM-INF:") ||
        line.startsWith("#EXT-X-RENDITION-REPORT:")
      ) kind = "playlist";
      const match = line.match(/URI=("([^"]*)"|([^,]*))/);
      if (!match) continue;
      const child = match[2] ?? match[3];
      const proxied = await this.proxyChildUrl(child, baseUrl, kind, profile, workerOrigin, secret);
      lines[index] = line.replace(match[0], `URI="${proxied}"`);
    }
    return lines.join("\n");
  },

  async proxyChildUrl(child, baseUrl, kind, profile, workerOrigin, secret) {
    const resolved = new URL(child, baseUrl).href;
    this.validateUpstreamUrl(resolved);
    return this.createMediaUrl(workerOrigin, resolved, kind, profile, secret);
  },

  async createMediaUrl(workerOrigin, upstreamUrl, kind, profile, secret) {
    const payload = {
      v: 1,
      url: upstreamUrl,
      kind,
      profile,
      exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
    };
    const token = this.base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
    const sig = await this.sign(token, secret);
    return `${workerOrigin}/api/media?token=${encodeURIComponent(token)}&sig=${encodeURIComponent(sig)}`;
  },

  async verifyMediaToken(token, signature, secret) {
    if (!token || !signature) throw new Error("Missing media token");
    if (token.length > 16384 || signature.length > 128) throw new Error("Media token is too large");
    const expected = await this.sign(token, secret);
    if (!this.constantTimeEqual(expected, signature)) throw new Error("Invalid media signature");
    const payload = JSON.parse(new TextDecoder().decode(this.base64UrlDecode(token)));
    if (payload.v !== 1 || !payload.url || !payload.kind || !payload.profile) {
      throw new Error("Invalid media token");
    }
    if (!["playlist", "segment", "key", "map"].includes(payload.kind)) {
      throw new Error("Invalid media resource kind");
    }
    if (!Number.isFinite(payload.exp) || payload.exp < Math.floor(Date.now() / 1000)) {
      throw new Error("Expired media token");
    }
    return payload;
  },

  async sign(value, secret) {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
    return this.base64UrlEncode(new Uint8Array(signature));
  },

  base64UrlEncode(bytes) {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },

  base64UrlDecode(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  },

  constantTimeEqual(left, right) {
    if (left.length !== right.length) return false;
    let difference = 0;
    for (let index = 0; index < left.length; index++) {
      difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
    }
    return difference === 0;
  },

  validateUpstreamUrl(value) {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.port) {
      throw new Error("Unsafe upstream URL");
    }
    const host = url.hostname.toLowerCase().replace(/\.$/, "");
    if (
      host === "localhost" ||
      host.endsWith(".localhost") ||
      host.endsWith(".local") ||
      host.endsWith(".internal") ||
      host === "0.0.0.0" ||
      host === "127.0.0.1" ||
      host === "169.254.169.254" ||
      host === "metadata.google.internal" ||
      /^10\./.test(host) ||
      /^192\.168\./.test(host) ||
      /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
      host === "::1" ||
      host === "[::1]" ||
      host.startsWith("fc") ||
      host.startsWith("fd") ||
      host.startsWith("fe80:")
    ) throw new Error("Private upstream URL is not allowed");
    return url;
  },

  async fetchWithRedirects(value, init) {
    let current = this.validateUpstreamUrl(value);
    for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects++) {
      const response = await fetch(current.href, { ...init, redirect: "manual" });
      if (![301, 302, 303, 307, 308].includes(response.status)) {
        return { response, effectiveUrl: current.href };
      }
      const location = response.headers.get("Location");
      if (!location || redirects === MAX_REDIRECTS) throw new Error("Invalid media redirect");
      current = this.validateUpstreamUrl(new URL(location, current).href);
    }
    throw new Error("Too many media redirects");
  },

  jsonError(message, status, corsHeaders) {
    return new Response(JSON.stringify({ error: message }), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  },

  // === VixSrc Extractor ===
  // Flow: API -> embed page -> parse JS vars -> construct playlist URL
  async extractVixSrc(tmdbId, isMovie, season, episode) {
    const apiUrl = isMovie
      ? `https://vixsrc.to/api/movie/${tmdbId}?lang=en`
      : `https://vixsrc.to/api/tv/${tmdbId}/${season}/${episode}?lang=en`;

    console.log(`VixSrc API: ${apiUrl}`);

    // Step 1: Call API to get embed path
    const apiResp = await fetch(apiUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://vixsrc.to",
        "X-Requested-With": "XMLHttpRequest",
      },
    });

    if (!apiResp.ok) throw new Error(`API ${apiResp.status}`);

    const apiData = await apiResp.json();
    let embedPath = (apiData.src || "").replace(/^\//, "");
    if (!embedPath) throw new Error("No embed path in API response");

    // Step 2: Fetch embed page
    const embedUrl = `https://vixsrc.to/${embedPath}`;
    console.log(`VixSrc embed: ${embedUrl}`);

    const embedResp = await fetch(embedUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://vixsrc.to",
      },
    });

    if (!embedResp.ok) throw new Error(`Embed ${embedResp.status}`);

    const html = await embedResp.text();

    // Step 3: Parse JS variables from HTML
    // window.video = { id: '...' }
    const videoSection = html.split("window.video = {")[1] || "";
    const videoId = this.between(videoSection, "id: '", "'");

    // window.masterPlaylist ... 'token': '...' ... 'expires': '...'
    const playlistSection = html.split("window.masterPlaylist")[1] || "";
    const token = this.between(playlistSection, "'token': '", "'");
    const expires = this.between(playlistSection, "'expires': '", "'");

    if (!videoId || !token || !expires) {
      throw new Error("Could not parse player parameters");
    }

    // Step 4: Construct playlist URL
    const queryParts = [`token=${encodeURIComponent(token)}`, `expires=${encodeURIComponent(expires)}`, "lang=en"];
    if (html.includes("b=1")) queryParts.push("b=1");
    if (html.includes("window.canPlayFHD = true")) queryParts.push("h=1");

    const playlistUrl = `https://vixsrc.to/playlist/${videoId}?${queryParts.join("&")}`;
    console.log(`VixSrc playlist: ${playlistUrl}`);

    // Step 5: Verify it's a valid HLS playlist
    const playlistResp = await fetch(playlistUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://vixsrc.to",
        "Origin": "https://vixsrc.to",
      },
    });

    if (!playlistResp.ok) throw new Error(`Playlist ${playlistResp.status}`);

    const playlistText = await playlistResp.text();
    if (!playlistText.trimStart().startsWith("#EXTM3U")) {
      throw new Error("Not a valid HLS playlist");
    }

    return {
      url: playlistUrl,
      source: "VixSrc",
      type: "hls",
      referer: "https://vixsrc.to",
    };
  },

  // === NetMirror Extractor ===
  // NetMirror (net79.cc) fronts a MovieBox CDN. /api/variants-tmdb gives the
  // language variants, /api/download-info gives the MP4 renditions and captions.
  async extractNetMirror(tmdbId, isMovie, season, episode) {
    const type = isMovie ? "movie" : "tv";
    const se = isMovie ? 0 : season;
    const ep = isMovie ? 0 : episode;
    const headers = { "User-Agent": USER_AGENT, Referer: `${NETMIRROR_BASE}/` };

    const variantsUrl =
      `${NETMIRROR_BASE}/api/variants-tmdb/${type}/${encodeURIComponent(tmdbId)}` +
      `?se=${se}&ep=${ep}`;
    const variants = await this.getJSONWithRetry(variantsUrl, headers);
    if (!variants || !variants.ok) {
      throw new Error(`NetMirror has no title for tmdb ${tmdbId}`);
    }

    const candidates = this.netMirrorCandidates(variants);
    if (candidates.length === 0) throw new Error("NetMirror returned no variants");

    let primary = null;
    for (const candidate of candidates) {
      const infoUrl =
        `${NETMIRROR_BASE}/api/download-info?subjectId=` +
        `${encodeURIComponent(candidate.subjectId)}&se=${se}&ep=${ep}`;
      try {
        const info = await this.getJSONWithRetry(infoUrl, headers);
        if (info && info.ok && Array.isArray(info.qualities) && info.qualities.length > 0) {
          primary = info;
          break;
        }
      } catch (e) {
        console.log(`NetMirror variant ${candidate.language || candidate.subjectId} failed: ${e.message}`);
      }
    }
    if (!primary) throw new Error(`NetMirror has no copy of this ${isMovie ? "movie" : "episode"}`);

    const qualities = (primary.qualities || [])
      .map((entry) => {
        const url = this.absolutize(entry && (entry.url || entry.raw), NETMIRROR_BASE);
        if (!url) return null;
        return {
          label: entry.res ? `${entry.res}p` : "Auto",
          url,
          height: Number(entry.res) || 0,
          codec: entry.codec || "h264",
          size: Number(entry.size) || 0,
        };
      })
      .filter(Boolean);
    if (qualities.length === 0) throw new Error("NetMirror returned no playable qualities");

    const chosen = this.pickDefaultQuality(qualities) || qualities[0];
    const subtitles = (primary.captions || [])
      .map((entry) => {
        const url = this.absolutize(entry && entry.url, NETMIRROR_BASE);
        if (!url) return null;
        return {
          language: entry.lang || entry.name || "Subtitle",
          url,
        };
      })
      .filter(Boolean);

    return {
      url: chosen.url,
      source: "NetMirror",
      type: this.mediaKind(chosen.url),
      referer: `${NETMIRROR_BASE}/`,
      qualities,
      subtitles,
    };
  },

  netMirrorCandidates(variants) {
    const seen = new Set();
    const candidates = [];
    const add = (subjectId, language) => {
      const value = String(subjectId || "").trim();
      if (!value || seen.has(value)) return;
      seen.add(value);
      candidates.push({ subjectId: value, language: String(language || "").trim() });
    };

    const list = Array.isArray(variants.variants) ? variants.variants : [];
    const defaultLanguage =
      list.find((entry) => String(entry && entry.dubSubjectId) === String(variants.defaultSubjectId))
        ?.language || "Default";
    add(variants.defaultSubjectId, defaultLanguage);
    for (const variant of list) add(variant && variant.dubSubjectId, variant && variant.language);
    return candidates.slice(0, 8);
  },

  // === VidLink Extractor ===
  // VidLink signs its /api/b/ path with XSalsa20-Poly1305: the token is
  // nonce(24) || secretbox(mediaId || be64(expiresAt)). The API answers
  // `null` under load, so retry before giving up.
  async extractVidLink(tmdbId, isMovie, season, episode) {
    const mediaId = String(tmdbId);
    const token = this.vidLinkToken(mediaId);
    const apiUrl = isMovie
      ? `${VIDLINK_BASE}/api/b/movie/${token}?multiLang=1`
      : `${VIDLINK_BASE}/api/b/tv/${token}/${season}/${episode}?multiLang=1`;

    console.log(`VidLink API: ${apiUrl}`);

    const headers = {
      "User-Agent": USER_AGENT,
      Referer: `${VIDLINK_BASE}/`,
      Origin: VIDLINK_BASE,
      "X-Playback-Environment": "standard",
    };

    let data = null;
    let lastError = null;
    for (let attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) await this.sleep(1200 * attempt);
      try {
        const response = await fetch(apiUrl, {
          headers,
          signal: AbortSignal.timeout(15000),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = (await response.text()).trim();
        if (!text || text === "null") throw new Error("empty response");
        const parsed = JSON.parse(text);
        if (!parsed || !parsed.stream) throw new Error("no stream");
        const stream = parsed.stream;
        if (Object.keys(stream.qualities || {}).length === 0 && !stream.playlist) {
          throw new Error("empty qualities");
        }
        data = parsed;
        break;
      } catch (error) {
        lastError = error;
        data = null;
      }
    }
    if (!data) throw new Error(`VidLink API failed (${lastError ? lastError.message : "empty response"})`);

    const stream = data.stream;
    const qualities = [];
    for (const [label, entry] of Object.entries(stream.qualities || {})) {
      const url = this.absolutize(entry && entry.url, VIDLINK_BASE);
      if (!url) continue;
      qualities.push({
        label: /p$/i.test(label) ? label : `${label}p`,
        url,
        height: parseInt(label, 10) || 0,
        codec:
          (entry && entry.codecName === "hevc") || this.looksLikeHevc(url) ? "hevc" : "h264",
      });
    }
    if (qualities.length === 0 && stream.playlist) {
      const url = this.absolutize(stream.playlist, VIDLINK_BASE);
      if (url) qualities.push({ label: "Auto", url, height: 0, codec: "h264" });
    }
    if (qualities.length === 0) throw new Error("VidLink returned no playable qualities");

    const chosen = this.pickDefaultQuality(qualities) || qualities[0];
    const pageUrl = isMovie
      ? `${VIDLINK_BASE}/movie/${mediaId}`
      : `${VIDLINK_BASE}/tv/${mediaId}/${season}/${episode}`;
    const subtitles = (stream.captions || [])
      .map((entry) => {
        const raw = String((entry && (entry.url || entry.id)) || "").trim();
        if (!raw) return null;
        const url = raw.startsWith("http") ? raw : this.absolutize(raw, pageUrl);
        if (!url) return null;
        return { language: entry.language || entry.label || "Subtitle", url };
      })
      .filter(Boolean);

    return {
      url: chosen.url,
      source: "VidLink",
      type: this.mediaKind(chosen.url),
      referer: `${VIDLINK_BASE}/`,
      qualities,
      subtitles,
    };
  },

  vidLinkToken(mediaId) {
    const expiresAt = Math.floor(Date.now() / 1000) + 480;
    const idBytes = new TextEncoder().encode(mediaId);
    const message = new Uint8Array(idBytes.length + 8);
    message.set(idBytes, 0);
    let remaining = expiresAt;
    for (let index = 7; index >= 0; index--) {
      message[idBytes.length + index] = remaining & 0xff;
      remaining = Math.floor(remaining / 256);
    }

    const key = this.fromHex(VIDLINK_API_KEY);
    const nonce = new Uint8Array(24);
    const sealed = secretbox(message, key, nonce);
    const token = new Uint8Array(nonce.length + sealed.length);
    token.set(nonce, 0);
    token.set(sealed, nonce.length);
    return this.base64UrlEncode(token);
  },

  // === 2Embed Extractor ===
  // === Goodstream Extractor ===
  // Fetches page and looks for jwplayer sources with file: "url" pattern
  async extractGoodstream(tmdbId, isMovie, season, episode) {
    const pageUrl = isMovie
      ? `https://goodstream.one/movie/${tmdbId}`
      : `https://goodstream.one/tv/${tmdbId}/${season}/${episode}`;

    console.log(`Goodstream page: ${pageUrl}`);

    const resp = await fetch(pageUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://goodstream.one",
      },
      redirect: "follow",
    });

    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

    const html = await resp.text();

    // Look for jwplayer sources: file: "url"
    const fileMatch = html.match(/file\s*:\s*["']([^"']+)["']/);
    if (fileMatch) {
      const url = fileMatch[1];
      if (url.includes(".m3u8")) {
        return {
          url: url.startsWith("http") ? url : `https://goodstream.one${url}`,
          source: "Goodstream",
          type: "hls",
          referer: "https://goodstream.one",
        };
      }
      return {
        url: url.startsWith("http") ? url : `https://goodstream.one${url}`,
        source: "Goodstream",
        type: "direct",
        referer: "https://goodstream.one",
      };
    }

    // Fallback: look for m3u8 URLs
    const m3u8Urls = this.extractUrls(html, /\.m3u8/);
    if (m3u8Urls.length > 0) {
      return {
        url: m3u8Urls[0],
        source: "Goodstream",
        type: "hls",
        referer: "https://goodstream.one",
      };
    }

    // Look for iframes
    const iframeMatch = html.match(/iframe[^>]+src=["']([^"']+)["']/i);
    if (iframeMatch) {
      let iframeUrl = iframeMatch[1];
      if (!iframeUrl.startsWith("http")) {
        iframeUrl = new URL(iframeUrl, pageUrl).href;
      }

      const iframeResp = await fetch(iframeUrl, {
        headers: {
          "User-Agent": USER_AGENT,
          "Referer": "https://goodstream.one",
        },
      });

      if (iframeResp.ok) {
        const iframeHtml = await iframeResp.text();
        const iframeFileMatch = iframeHtml.match(/file\s*:\s*["']([^"']+)["']/);
        if (iframeFileMatch) {
          const url = iframeFileMatch[1];
          return {
            url: url.startsWith("http") ? url : new URL(url, iframeUrl).href,
            source: "Goodstream",
            type: url.includes(".m3u8") ? "hls" : "direct",
            referer: iframeUrl,
          };
        }

        const iframeM3u8 = this.extractUrls(iframeHtml, /\.m3u8/);
        if (iframeM3u8.length > 0) {
          return {
            url: iframeM3u8[0],
            source: "Goodstream",
            type: "hls",
            referer: iframeUrl,
          };
        }
      }
    }

    return null;
  },

  async extract2Embed(tmdbId, isMovie, season, episode) {
    const pageUrl = isMovie
      ? `https://www.2embed.cc/embed/${tmdbId}`
      : `https://www.2embed.cc/embedtv/${tmdbId}&s=${season}&e=${episode}`;

    console.log(`2Embed page: ${pageUrl}`);

    const resp = await fetch(pageUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://www.2embed.cc",
      },
      redirect: "follow",
    });

    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

    const html = await resp.text();

    // Look for iframes
    const iframeMatch = html.match(/iframe[^>]+src=["']([^"']+)["']/i);
    if (iframeMatch) {
      let iframeUrl = iframeMatch[1];
      if (!iframeUrl.startsWith("http")) {
        iframeUrl = new URL(iframeUrl, pageUrl).href;
      }

      console.log(`2Embed iframe: ${iframeUrl}`);

      const iframeResp = await fetch(iframeUrl, {
        headers: {
          "User-Agent": USER_AGENT,
          "Referer": pageUrl,
        },
      });

      if (iframeResp.ok) {
        const iframeHtml = await iframeResp.text();

        // Look for m3u8
        const m3u8Urls = this.extractUrls(iframeHtml, /\.m3u8/);
        if (m3u8Urls.length > 0) {
          return {
            url: m3u8Urls[0],
            source: "2Embed",
            type: "hls",
            referer: iframeUrl,
          };
        }

        // Look for video source
        const videoUrls = this.extractUrls(iframeHtml, /\.(mp4|webm)/);
        if (videoUrls.length > 0) {
          return {
            url: videoUrls[0],
            source: "2Embed",
            type: "direct",
            referer: iframeUrl,
          };
        }

        // Look for nested iframes
        const nestedIframe = iframeHtml.match(/iframe[^>]+src=["']([^"']+)["']/i);
        if (nestedIframe) {
          let nestedUrl = nestedIframe[1];
          if (!nestedUrl.startsWith("http")) {
            nestedUrl = new URL(nestedUrl, iframeUrl).href;
          }

          const nestedResp = await fetch(nestedUrl, {
            headers: {
              "User-Agent": USER_AGENT,
              "Referer": iframeUrl,
            },
          });

          if (nestedResp.ok) {
            const nestedHtml = await nestedResp.text();
            const nestedM3u8 = this.extractUrls(nestedHtml, /\.m3u8/);
            if (nestedM3u8.length > 0) {
              return {
                url: nestedM3u8[0],
                source: "2Embed",
                type: "hls",
                referer: nestedUrl,
              };
            }
          }
        }
      }
    }

    return null;
  },

  // === Health Check ===
  // The website's /status page expects { servers, extractors, summary }.
  // Probes are cached for 5 minutes so refreshing the page does not hammer
  // the upstream providers.
  async handleHealth(url, corsHeaders, env) {
    const CACHE_TTL = 300;
    const cache = caches.default;
    const cacheKey = new Request(`${url.origin}/health`, { method: "GET" });
    const cached = await cache.match(cacheKey);
    if (cached) {
      return new Response(await cached.text(), {
        headers: { ...corsHeaders, "Content-Type": "application/json", "X-Cache": "HIT" },
      });
    }

    // Mirrors the servers the apps expose.
    const servers = [
      { name: "NetMirror", domain: "net79.cc" },
      { name: "VixSrc", domain: "vixsrc.to" },
      { name: "VidLink", domain: "vidlink.pro" },
      { name: "Videasy", domain: "player.videasy.to" },
    ];

    // Extractors implemented by the apps / this worker.
    const extractors = [
      { name: "NetMirror", domain: "net79.cc", kind: "api" },
      { name: "VixSrc", domain: "vixsrc.to", kind: "api" },
      { name: "VidLink", domain: "vidlink.pro", kind: "api" },
      { name: "Videasy", domain: "player.videasy.to", kind: "api" },
      { name: "2Embed", domain: "www.2embed.cc", kind: "native" },
      { name: "Goodstream", domain: "goodstream.one", kind: "native" },
    ];

    const checkProvider = async (provider, type) => {
      const startedAt = Date.now();
      try {
        const response = await fetch(`https://${provider.domain}`, {
          method: "HEAD",
          headers: { "User-Agent": USER_AGENT },
          redirect: "follow",
          signal: AbortSignal.timeout(8000),
        });
        return {
          name: provider.name,
          domain: provider.domain,
          type,
          kind: provider.kind || null,
          healthy: response.status > 0 && response.status < 500,
          status: response.status,
          responseMs: Date.now() - startedAt,
        };
      } catch (error) {
        return {
          name: provider.name,
          domain: provider.domain,
          type,
          kind: provider.kind || null,
          healthy: false,
          status: 0,
          responseMs: Date.now() - startedAt,
          error: error.name === "TimeoutError" ? "Timeout" : String(error.message || "Failed").slice(0, 60),
        };
      }
    };

    const [serverResults, extractorResults] = await Promise.all([
      Promise.all(servers.map((provider) => checkProvider(provider, "server"))),
      Promise.all(extractors.map((provider) => checkProvider(provider, "extractor"))),
    ]);

    const payload = {
      status: "ok",
      service: "maxstream-extractor",
      proxyConfigured: Boolean(env.PROXY_SECRET),
      timestamp: new Date().toISOString(),
      servers: serverResults,
      extractors: extractorResults,
      summary: {
        servers: {
          total: serverResults.length,
          healthy: serverResults.filter((result) => result.healthy).length,
          unhealthy: serverResults.filter((result) => !result.healthy).length,
        },
        extractors: {
          total: extractorResults.length,
          healthy: extractorResults.filter((result) => result.healthy).length,
          unhealthy: extractorResults.filter((result) => !result.healthy).length,
        },
      },
    };

    try {
      await cache.put(
        cacheKey,
        new Response(JSON.stringify(payload), {
          headers: { "Content-Type": "application/json", "Cache-Control": `max-age=${CACHE_TTL}` },
        })
      );
    } catch (_) {
      // Caching is best-effort.
    }

    return new Response(JSON.stringify(payload), {
      headers: { ...corsHeaders, "Content-Type": "application/json", "X-Cache": "MISS" },
    });
  },

  // === Utility Functions ===

  async getJSONWithRetry(url, headers, attempts = 3) {
    let lastError = null;
    for (let attempt = 1; attempt <= attempts; attempt++) {
      try {
        const response = await fetch(url, {
          headers,
          signal: AbortSignal.timeout(15000),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = await response.text();
        try {
          return JSON.parse(text);
        } catch (_) {
          throw new Error("Invalid JSON");
        }
      } catch (error) {
        lastError = error;
        if (attempt < attempts) await this.sleep(300 * attempt);
      }
    }
    throw lastError || new Error("Request failed");
  },

  sleep(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  },

  fromHex(hex) {
    if (hex.length % 2 !== 0) throw new Error("Invalid hex string");
    const out = new Uint8Array(hex.length / 2);
    for (let index = 0; index < out.length; index++) {
      out[index] = parseInt(hex.slice(index * 2, index * 2 + 2), 16);
    }
    return out;
  },

  absolutize(value, base) {
    if (!value || typeof value !== "string") return "";
    if (value.startsWith("http")) return value;
    if (value.startsWith("//")) return `https:${value}`;
    try {
      return new URL(value, base).href;
    } catch (_) {
      return "";
    }
  },

  mediaKind(value) {
    const url = String(value || "").toLowerCase();
    if (url.includes(".m3u8")) return "hls";
    if (url.includes(".mpd")) return "dash";
    return "direct";
  },

  looksLikeHevc(value) {
    const url = String(value || "").toLowerCase();
    return [
      "/h265/", "/h.265/", "/hevc/",
      "_h265_", "_hevc_", "-h265-", "-hevc-",
    ].some((pattern) => url.includes(pattern));
  },

  // Default pick: highest H.264 rendition; HEVC only when it is all that exists.
  pickDefaultQuality(qualities) {
    const list = qualities || [];
    if (list.length === 0) return null;
    const h264 = list.filter((entry) => entry.codec !== "hevc" && entry.height > 0);
    const pool = h264.length > 0 ? h264 : list.filter((entry) => entry.codec !== "hevc");
    const candidates = pool.length > 0 ? pool : list;
    return candidates.reduce((best, entry) => (entry.height > best.height ? entry : best));
  },

  extractUrls(html, pattern) {
    const urls = new Set();
    const source = pattern instanceof RegExp ? pattern.source : String(pattern);
    const regex = new RegExp(`["'](https?://[^"'<>]*${source}[^"'<>]*)["']`, "gi");
    let match;
    while ((match = regex.exec(html)) !== null) {
      let url = match[1];
      if (url.startsWith("//")) url = "https:" + url;
      urls.add(url);
    }
    // Also check for relative URLs
    const relRegex = new RegExp(`["']([^"'<>]*${source}[^"'<>]*)["']`, "gi");
    while ((match = relRegex.exec(html)) !== null) {
      const url = match[1];
      if (url.startsWith("http") || url.startsWith("//")) {
        urls.add(url.startsWith("//") ? "https:" + url : url);
      }
    }
    return [...urls];
  },

  between(str, start, end) {
    const startIdx = str.indexOf(start);
    if (startIdx === -1) return null;
    const afterStart = str.substring(startIdx + start.length);
    const endIdx = afterStart.indexOf(end);
    if (endIdx === -1) return null;
    return afterStart.substring(0, endIdx);
  },
};
