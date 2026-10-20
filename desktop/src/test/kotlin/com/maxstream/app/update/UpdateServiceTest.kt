package com.maxstream.app.update

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UpdateServiceTest {
    @Test
    fun comparesVersionsNumerically() {
        assertTrue(compareVersions("1.0.10", "1.0.9") > 0)
        assertTrue(compareVersions("1.1.0", "1.0.99") > 0)
        assertEquals(0, compareVersions("1.0.1", "1.0.1"))
        assertEquals(0, compareVersions("1.0", "1.0.0"))
        assertTrue(compareVersions("1.0.1", "2.0.0") < 0)
    }
}
