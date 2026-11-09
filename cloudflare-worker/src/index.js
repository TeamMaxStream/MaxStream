/// Cloudflare Worker: MaxStream Stream Extractor
/// Extracts .m3u8 URLs server-side via HTTP requests and regex parsing.
/// No iframes, no popups, no ads.

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const TOKEN_TTL_SECONDS = 6 * 60 * 60;
const MAX_REDIRECTS = 5;
const MAX_PLAYLIST_BYTES = 2 * 1024 * 1024;

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
      return new Response(
        JSON.stringify({
          status: "ok",
          service: "maxstream-extractor",
          proxyConfigured: Boolean(env.PROXY_SECRET),
          timestamp: new Date().toISOString(),
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
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
    const tmdbId = url.searchParams.get("tmdb_id");
    const isMovie = url.searchParams.get("is_movie") === "true";
    const season = parseInt(url.searchParams.get("season") || "1");
    const episode = parseInt(url.searchParams.get("episode") || "1");
    const server = url.searchParams.get("server"); // Optional: "vixsrc", "vidlink", "2embed"

    if (!tmdbId) {
      return new Response(JSON.stringify({ error: "tmdb_id required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    console.log(`Extract: TMDB ${tmdbId} movie=${isMovie} s${season}e${episode} server=${server || 'all'}`);

    // If specific server requested, only try that one
    if (server) {
      try {
        let result;
        if (server === "vixsrc") result = await this.extractVixSrc(tmdbId, isMovie, season, episode);
        else if (server === "vidlink") result = await this.extractVidLink(tmdbId, isMovie, season, episode);
        else if (server === "2embed") result = await this.extract2Embed(tmdbId, isMovie, season, episode);
        else if (server === "goodstream") result = await this.extractGoodstream(tmdbId, isMovie, season, episode);

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

    // Try all servers in order
    try {
      const result = await this.extractVixSrc(tmdbId, isMovie, season, episode);
      if (result) {
        console.log(`VixSrc success: ${result.url}`);
        const publicResult = await this.createPublicResult(result, env, workerOrigin);
        return new Response(JSON.stringify(publicResult), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } catch (e) {
      console.log(`VixSrc failed: ${e.message}`);
    }

    // Try VidLink (fetch page, look for /api/b/ pattern)
    try {
      const result = await this.extractVidLink(tmdbId, isMovie, season, episode);
      if (result) {
        console.log(`VidLink success: ${result.url}`);
        const publicResult = await this.createPublicResult(result, env, workerOrigin);
        return new Response(JSON.stringify(publicResult), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } catch (e) {
      console.log(`VidLink failed: ${e.message}`);
    }

    // Try 2Embed
    try {
      const result = await this.extract2Embed(tmdbId, isMovie, season, episode);
      if (result) {
        console.log(`2Embed success: ${result.url}`);
        const publicResult = await this.createPublicResult(result, env, workerOrigin);
        return new Response(JSON.stringify(publicResult), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } catch (e) {
      console.log(`2Embed failed: ${e.message}`);
    }

    // Try Goodstream
    try {
      const result = await this.extractGoodstream(tmdbId, isMovie, season, episode);
      if (result) {
        console.log(`Goodstream success: ${result.url}`);
        const publicResult = await this.createPublicResult(result, env, workerOrigin);
        return new Response(JSON.stringify(publicResult), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } catch (e) {
      console.log(`Goodstream failed: ${e.message}`);
    }

    return new Response(JSON.stringify({ error: "No stream found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  },

  async createPublicResult(result, env, workerOrigin) {
    if (!env.PROXY_SECRET) throw new Error("PROXY_SECRET is not configured");
    if (result.type !== "hls") throw new Error("Only HLS streams are supported on web");
    this.validateUpstreamUrl(result.url);
    const profile = this.profileForResult(result);
    const url = await this.createMediaUrl(
      workerOrigin,
      result.url,
      "playlist",
      profile,
      env.PROXY_SECRET
    );
    return { url, source: result.source, type: "hls" };
  },

  profileForResult(result) {
    const source = result.source || "";
    if (source === "VixSrc") return "vixsrc";
    if (source === "VidLink") return "vidlink";
    if (source === "2Embed") return "2embed";
    if (source === "Goodstream") return "goodstream";
    throw new Error("Unsupported provider profile");
  },

  profileHeaders(profile) {
    const headers = { "User-Agent": USER_AGENT };
    if (profile === "vixsrc") {
      headers.Referer = "https://vixsrc.to/";
      headers.Origin = "https://vixsrc.to";
    } else if (profile === "vidlink") {
      headers.Referer = "https://vidlink.pro/";
      headers.Origin = "https://vidlink.pro";
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
      const headers = this.profileHeaders(payload.profile);
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

  // === VidLink Extractor ===
  // VidLink is a React app - we need to find the /api/b/ endpoint
  async extractVidLink(tmdbId, isMovie, season, episode) {
    const pageUrl = isMovie
      ? `https://vidlink.pro/movie/${tmdbId}`
      : `https://vidlink.pro/tv/${tmdbId}/${season}/${episode}`;

    console.log(`VidLink page: ${pageUrl}`);

    const resp = await fetch(pageUrl, {
      headers: {
        "User-Agent": USER_AGENT,
        "Referer": "https://vidlink.pro",
      },
      redirect: "follow",
    });

    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

    const html = await resp.text();

    // Look for /api/b/ URLs in the HTML
    const apiMatch = html.match(/["'](\/api\/b\/[^"']+)["']/);
    if (apiMatch) {
      const apiUrl = `https://vidlink.pro${apiMatch[1]}`;
      console.log(`VidLink API: ${apiUrl}`);

      const apiResp = await fetch(apiUrl, {
        headers: {
          "User-Agent": USER_AGENT,
          "Referer": pageUrl,
        },
      });

      if (apiResp.ok) {
        const data = await apiResp.json();
        const playlist = data?.stream?.playlist;
        if (playlist) {
          return {
            url: playlist.startsWith("http") ? playlist : `https://vidlink.pro${playlist}`,
            source: "VidLink",
            type: "hls",
            referer: "https://vidlink.pro",
          };
        }
      }
    }

    // Look for m3u8 URLs directly in the HTML
    const m3u8Urls = this.extractUrls(html, /\.m3u8/);
    if (m3u8Urls.length > 0) {
      return {
        url: m3u8Urls[0],
        source: "VidLink",
        type: "hls",
        referer: "https://vidlink.pro",
      };
    }

    // Look for iframes that might contain the player
    const iframeMatch = html.match(/iframe[^>]+src=["']([^"']+)["']/i);
    if (iframeMatch) {
      const iframeUrl = new URL(iframeMatch[1], pageUrl).href;
      console.log(`VidLink iframe: ${iframeUrl}`);

      const iframeResp = await fetch(iframeUrl, {
        headers: {
          "User-Agent": USER_AGENT,
          "Referer": pageUrl,
        },
      });

      if (iframeResp.ok) {
        const iframeHtml = await iframeResp.text();
        const iframeM3u8 = this.extractUrls(iframeHtml, /\.m3u8/);
        if (iframeM3u8.length > 0) {
          return {
            url: iframeM3u8[0],
            source: "VidLink",
            type: "hls",
            referer: "https://vidlink.pro",
          };
        }
      }
    }

    return null;
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

  // === Utility Functions ===

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
