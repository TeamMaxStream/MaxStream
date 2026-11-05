package com.maxstream.app

import java.io.File
import java.security.MessageDigest

/**
 * Streaming SHA-256 helpers for verifying downloaded release artifacts.
 *
 * Shared by the TV and (via its own copy) desktop updaters; hashing is streamed
 * because installers are 40–100 MB and never need to sit in memory at once.
 */
object Sha256 {
    fun fileHex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Parses `sha256sum`-style output (`<64 hex>  <filename>` per line) and
     * returns the lowercase checksum for [fileName], or null when absent.
     */
    fun findForFile(sums: String, fileName: String): String? {
        for (raw in sums.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val match = Regex("^([0-9a-fA-F]{64})\\s+\\*?(.+)$").find(line) ?: continue
            val name = match.groupValues[2].trim()
            if (name == fileName || name.endsWith("/$fileName")) {
                return match.groupValues[1].lowercase()
            }
        }
        return null
    }
}
