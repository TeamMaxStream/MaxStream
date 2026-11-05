package com.maxstream.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Base64

class SalsaSecretBoxTest {

    private fun hexToBytes(hex: String): ByteArray = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Known-good VidLink token produced by enc-dec.app; decrypts to "299534" + BE timestamp.
    // Decoded structure: 24-byte zero nonce || mac(16) || ciphertext.
    private val knownToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAnNt2Q_R4DRs7F_W3_BXD1cKKAct-dFYZ2cQg_6qP"

    @Test
    fun secretboxMatchesPyNaCl() {
        val key = hexToBytes("c75136c5668bbfe65a7ecad431a745db68b5f381555b38d8f6c699449cf11fcd")
        val nonce = ByteArray(24)
        val message = "299534".toByteArray() + byteArrayOf(0x00, 0x00, 0x00, 0x00, 0x6a, 0x77, 0x0c, 0xb7)

        // Expected mac||ct from PyNaCl SecretBox.encrypt for this exact input.
        val expected = Base64.getUrlDecoder().decode(knownToken).copyOfRange(24, 54)
        val actual = SalsaSecretBox.secretboxDetached(message, key, nonce)

        assertArrayEquals(expected, actual)
    }

    @Test
    fun roundTripWithSelf() {
        val key = hexToBytes("c75136c5668bbfe65a7ecad431a745db68b5f381555b38d8f6c699449cf11fcd")
        val nonce = ByteArray(24)
        val message = "1396".toByteArray() + byteArrayOf(0x00, 0x00, 0x00, 0x00, 0x7a, 0x69, 0x0c, 0xb7)
        val enc = SalsaSecretBox.secretboxDetached(message, key, nonce)
        assertEquals(16 + message.size, enc.size)
    }
}
