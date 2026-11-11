package com.maxstream.app.stream

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SubtitlePickTest {

    private fun sub(label: String, language: String = "", isDefault: Boolean = false) =
        ResolvedSubtitle(label, "https://example.test/$label.vtt", isDefault, language)

    @Test
    fun emptyListPicksNothing() {
        assertNull(pickDefaultSubtitle(emptyList()))
    }

    @Test
    fun explicitDefaultWins() {
        val picked = pickDefaultSubtitle(
            listOf(sub("Spanish", "es"), sub("English", "en", isDefault = true)),
            audioLanguage = "es",
        )
        assertEquals("English", picked?.label)
    }

    @Test
    fun audioLanguageWinsWithoutDefault() {
        val picked = pickDefaultSubtitle(
            listOf(sub("English", "en"), sub("Spanish", "es"), sub("French", "fr")),
            audioLanguage = "es",
        )
        assertEquals("Spanish", picked?.label)
    }

    @Test
    fun fallsBackToEnglishThenFirst() {
        assertEquals(
            "English",
            pickDefaultSubtitle(listOf(sub("Français", "fr"), sub("English", "en")), "de")?.label,
        )
        assertEquals(
            "Deutsch",
            pickDefaultSubtitle(listOf(sub("Deutsch", "de"), sub("Italiano", "it")), "xx")?.label,
        )
    }

    @Test
    fun matchesFullLanguageNamesInLabels() {
        val picked = pickDefaultSubtitle(
            listOf(sub("Spanish"), sub("English"), sub("Portuguese")),
            audioLanguage = "Português",
        )
        assertEquals("Portuguese", picked?.label)
    }

    @Test
    fun displayUsesLanguageName() {
        assertEquals("English", sub("en").display())
        assertEquals("English", sub("English", "en").display())
        assertEquals("English", sub("", "en-US").display())
        assertEquals("English", sub("eng").display())
        assertEquals("Spanish", sub("Español", "es").display())
        assertEquals("Forced (English)", sub("Forced", "en").display())
        assertEquals("Custom", sub("Custom").display())
    }
}
