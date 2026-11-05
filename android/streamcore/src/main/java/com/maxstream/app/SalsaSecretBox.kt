package com.maxstream.app

import java.math.BigInteger

/**
 * Pure-Kotlin XSalsa20-Poly1305 secretbox (libsodium crypto_secretbox_detached).
 *
 * Ported from a pure-Python implementation that was cross-validated against
 * libsodium test vectors (core1/core5 hsalsa20) and PyNaCl secretbox, and used
 * to produce tokens accepted by VidLink's /api/b/ endpoints.
 */
internal object SalsaSecretBox {
    private const val SIGMA0 = 0x61707865L
    private const val SIGMA1 = 0x3320646eL
    private const val SIGMA2 = 0x79622d32L
    private const val SIGMA3 = 0x6b206574L
    private const val MASK = 0xffffffffL

    private fun rotl(v: Long, c: Int): Long {
        val x = v and MASK
        return ((x shl c) and MASK) or (x ushr (32 - c))
    }

    /** Ten salsa20 double rounds, no feed-forward. Mutates the 16-word array. */
    private fun salsaRounds(x: LongArray) {
        var x0 = x[0]; var x1 = x[1]; var x2 = x[2]; var x3 = x[3]
        var x4 = x[4]; var x5 = x[5]; var x6 = x[6]; var x7 = x[7]
        var x8 = x[8]; var x9 = x[9]; var x10 = x[10]; var x11 = x[11]
        var x12 = x[12]; var x13 = x[13]; var x14 = x[14]; var x15 = x[15]
        repeat(10) {
            x4 = x4 xor rotl(x0 + x12, 7); x8 = x8 xor rotl(x4 + x0, 9)
            x12 = x12 xor rotl(x8 + x4, 13); x0 = x0 xor rotl(x12 + x8, 18)
            x9 = x9 xor rotl(x5 + x1, 7); x13 = x13 xor rotl(x9 + x5, 9)
            x1 = x1 xor rotl(x13 + x9, 13); x5 = x5 xor rotl(x1 + x13, 18)
            x14 = x14 xor rotl(x10 + x6, 7); x2 = x2 xor rotl(x14 + x10, 9)
            x6 = x6 xor rotl(x2 + x14, 13); x10 = x10 xor rotl(x6 + x2, 18)
            x3 = x3 xor rotl(x15 + x11, 7); x7 = x7 xor rotl(x3 + x15, 9)
            x11 = x11 xor rotl(x7 + x3, 13); x15 = x15 xor rotl(x11 + x7, 18)
            x1 = x1 xor rotl(x0 + x3, 7); x2 = x2 xor rotl(x1 + x0, 9)
            x3 = x3 xor rotl(x2 + x1, 13); x0 = x0 xor rotl(x3 + x2, 18)
            x6 = x6 xor rotl(x5 + x4, 7); x7 = x7 xor rotl(x6 + x5, 9)
            x4 = x4 xor rotl(x7 + x6, 13); x5 = x5 xor rotl(x4 + x7, 18)
            x11 = x11 xor rotl(x10 + x9, 7); x8 = x8 xor rotl(x11 + x10, 9)
            x9 = x9 xor rotl(x8 + x11, 13); x10 = x10 xor rotl(x9 + x8, 18)
            x12 = x12 xor rotl(x15 + x14, 7); x13 = x13 xor rotl(x12 + x15, 9)
            x14 = x14 xor rotl(x13 + x12, 13); x15 = x15 xor rotl(x14 + x13, 18)
        }
        x[0] = x0 and MASK; x[1] = x1 and MASK; x[2] = x2 and MASK; x[3] = x3 and MASK
        x[4] = x4 and MASK; x[5] = x5 and MASK; x[6] = x6 and MASK; x[7] = x7 and MASK
        x[8] = x8 and MASK; x[9] = x9 and MASK; x[10] = x10 and MASK; x[11] = x11 and MASK
        x[12] = x12 and MASK; x[13] = x13 and MASK; x[14] = x14 and MASK; x[15] = x15 and MASK
    }

    private fun leWords(data: ByteArray): LongArray {
        val out = LongArray(data.size / 4)
        for (i in out.indices) {
            val b = i * 4
            out[i] = (data[b].toLong() and 0xff) or
                ((data[b + 1].toLong() and 0xff) shl 8) or
                ((data[b + 2].toLong() and 0xff) shl 16) or
                ((data[b + 3].toLong() and 0xff) shl 24)
        }
        return out
    }

    private fun packLe(vararg words: Long): ByteArray {
        val out = ByteArray(words.size * 4)
        for (i in words.indices) {
            val v = words[i] and MASK
            val b = i * 4
            out[b] = (v and 0xff).toByte()
            out[b + 1] = ((v ushr 8) and 0xff).toByte()
            out[b + 2] = ((v ushr 16) and 0xff).toByte()
            out[b + 3] = ((v ushr 24) and 0xff).toByte()
        }
        return out
    }

    /** Salsa20 block with feed-forward (crypto_core_salsa20, c = sigma). */
    private fun salsa20Block(key: ByteArray, nonce: ByteArray, counter: Long): ByteArray {
        val k = leWords(key)
        val n = leWords(nonce)
        val x = longArrayOf(
            SIGMA0, k[0], k[1], k[2], k[3],
            SIGMA1, n[0], n[1], counter and MASK, (counter ushr 32) and MASK,
            SIGMA2, k[4], k[5], k[6], k[7],
            SIGMA3,
        )
        val orig = x.copyOf()
        salsaRounds(x)
        val out = ByteArray(64)
        for (i in 0 until 16) {
            val v = (x[i] + orig[i]) and MASK
            val b = i * 4
            out[b] = (v and 0xff).toByte()
            out[b + 1] = ((v ushr 8) and 0xff).toByte()
            out[b + 2] = ((v ushr 16) and 0xff).toByte()
            out[b + 3] = ((v ushr 24) and 0xff).toByte()
        }
        return out
    }

    /** Salsa20 stream XOR (crypto_stream_salsa20_xor_ic). */
    private fun salsa20Xor(data: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray {
        val out = data.copyOf()
        var offset = 0
        var counter = 0L
        while (offset < data.size) {
            val block = salsa20Block(key, nonce, counter++)
            val length = minOf(64, data.size - offset)
            for (i in 0 until length) {
                out[offset + i] = (out[offset + i].toInt() xor block[i].toInt()).toByte()
            }
            offset += length
        }
        return out
    }

    /** HSalsa20: key(32) + nonce(16) -> 32-byte subkey (no feed-forward). */
    private fun hsalsa20(key: ByteArray, nonce: ByteArray): ByteArray {
        val k = leWords(key)
        val n = leWords(nonce)
        val x = longArrayOf(
            SIGMA0, k[0], k[1], k[2], k[3],
            SIGMA1, n[0], n[1], n[2], n[3],
            SIGMA2, k[4], k[5], k[6], k[7],
            SIGMA3,
        )
        salsaRounds(x)
        return packLe(x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9])
    }

    private val P = (BigInteger.ONE.shiftLeft(130)).subtract(BigInteger.valueOf(5))
    private val MASK128 = (BigInteger.ONE.shiftLeft(128)).subtract(BigInteger.ONE)

    /** Poly1305 one-time authenticator (RFC 8439). */
    private fun poly1305(msg: ByteArray, key32: ByteArray): ByteArray {
        val rBytes = key32.copyOfRange(0, 16)
        rBytes[3] = (rBytes[3].toInt() and 0x0f).toByte()
        rBytes[7] = (rBytes[7].toInt() and 0x0f).toByte()
        rBytes[11] = (rBytes[11].toInt() and 0x0f).toByte()
        rBytes[15] = (rBytes[15].toInt() and 0x0f).toByte()
        rBytes[4] = (rBytes[4].toInt() and 0xfc).toByte()
        rBytes[8] = (rBytes[8].toInt() and 0xfc).toByte()
        rBytes[12] = (rBytes[12].toInt() and 0xfc).toByte()
        val r = BigInteger(1, rBytes.reversedArray())
        val s = BigInteger(1, key32.copyOfRange(16, 32).reversedArray())
        var h = BigInteger.ZERO
        var offset = 0
        while (offset < msg.size) {
            val length = minOf(16, msg.size - offset)
            val block = msg.copyOfRange(offset, offset + length) + byteArrayOf(0x01)
            val n = BigInteger(1, block.reversedArray())
            h = h.add(n).multiply(r).mod(P)
            offset += length
        }
        h = h.add(s).and(MASK128)
        val out = ByteArray(16)
        val bytes = h.toByteArray()
        for (i in bytes.indices) {
            val target = bytes.size - 1 - i
            if (target < 16) out[target] = bytes[i]
        }
        return out
    }

    /**
     * Secretbox detached output: mac(16) || ciphertext.
     * Key 32 bytes, nonce 24 bytes.
     */
    fun secretboxDetached(message: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray {
        val subkey = hsalsa20(key, nonce.copyOfRange(0, 16))
        val streamNonce = nonce.copyOfRange(16, 24)
        val keystream = salsa20Xor(ByteArray(32 + message.size), subkey, streamNonce)
        val polyKey = keystream.copyOfRange(0, 32)
        val ciphertext = ByteArray(message.size)
        for (i in message.indices) {
            ciphertext[i] = (message[i].toInt() xor keystream[32 + i].toInt()).toByte()
        }
        val mac = poly1305(ciphertext, polyKey)
        return mac + ciphertext
    }
}
