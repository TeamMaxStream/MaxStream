package com.maxstream.app

/**
 * Extracts stream URLs from goodstream.one.
 * Fetches the page and looks for jwplayer sources with file: "url" pattern.
 */
class GoodstreamExtractor {
    private val tag = "GoodstreamExtractor"
    private val userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    fun extract(html: String, baseUrl: String): Map<String, Any>? {
        // Look for jwplayer sources: file: "url"
        val fileRegex = Regex("""file\s*:\s*["']([^"']+)["']""")
        val match = fileRegex.find(html)

        if (match != null) {
            val streamUrl = match.groupValues[1]
            android.util.Log.d(tag, "Found stream: $streamUrl")

            val headers = mapOf(
                "User-Agent" to userAgent,
                "Referer" to "https://goodstream.one"
            )

            return mapOf(
                "url" to streamUrl,
                "source" to "Goodstream",
                "type" to if (streamUrl.contains(".m3u8")) "direct_m3u8" else "direct",
                "headers" to headers
            )
        }

        // Fallback: look for m3u8 URLs
        val m3u8Regex = Regex("""["'](https?://[^"']*\.m3u8[^"']*)["']""")
        val m3u8Match = m3u8Regex.find(html)
        if (m3u8Match != null) {
            val streamUrl = m3u8Match.groupValues[1]
            android.util.Log.d(tag, "Found m3u8: $streamUrl")

            val headers = mapOf(
                "User-Agent" to userAgent,
                "Referer" to "https://goodstream.one"
            )

            return mapOf(
                "url" to streamUrl,
                "source" to "Goodstream",
                "type" to "direct_m3u8",
                "headers" to headers
            )
        }

        return null
    }
}
