package com.maxstream.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MaxStream brand palette — matches the TV app (Netflix-red primary, white
// on-primary) so the desktop client feels like the same product. Dark is the
// signature look; light keeps readable surfaces for the Settings toggle.
private val MaxRed = Color(0xFFE50914)
private val MaxRedDark = Color(0xFFB00710)
private val MaxCoral = Color(0xFFFF5A5F)

private val LightColors = lightColorScheme(
    primary = MaxRed,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDAD6),
    onPrimaryContainer = Color(0xFF410002),
    secondary = MaxCoral,
    onSecondary = Color.Black,
    secondaryContainer = Color(0xFFFFDAD6),
    onSecondaryContainer = Color(0xFF410002),
    tertiary = Color(0xFF7A5900),
    background = Color(0xFFFFFBFF),
    onBackground = Color(0xFF201A1A),
    surface = Color(0xFFFFFBFF),
    onSurface = Color(0xFF201A1A),
    surfaceVariant = Color(0xFFF5DDDA),
    onSurfaceVariant = Color(0xFF534341),
    outline = Color(0xFF857370),
    outlineVariant = Color(0xFFD8C2BF),
    // M3 light error tone — the old value was the *dark* palette's error,
    // which reads washed-out on light surfaces.
    error = Color(0xFFB3261E),
    onError = Color.White,
)

private val DarkColors = darkColorScheme(
    primary = MaxRed,
    onPrimary = Color.White,
    primaryContainer = MaxRedDark,
    onPrimaryContainer = Color(0xFFFFDAD6),
    secondary = MaxCoral,
    onSecondary = Color.Black,
    secondaryContainer = Color(0xFF8C3D3F),
    onSecondaryContainer = Color(0xFFFFDAD6),
    tertiary = Color(0xFFF5C242),
    background = Color(0xFF0D0D0F),
    onBackground = Color(0xFFFFFFFF),
    surface = Color(0xFF1A1A1E),
    onSurface = Color.White,
    // Slightly lifted from #1E1E1E: it sat ~1.5% above `surface`, making
    // skeletons, tracks and the nav-rail backdrop nearly invisible.
    surfaceVariant = Color(0xFF25252C),
    onSurfaceVariant = Color(0xFFB3B3B3),
    outline = Color(0xFF74777F),
    outlineVariant = Color(0xFF444850),
    error = Color(0xFFCF6679),
    onError = Color.Black,
)

// Streaming-app scale: tight display sizes for heroes, comfortable body text.
private val MaxStreamTypography = Typography(
    displayLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 48.sp,
        lineHeight = 54.sp,
        letterSpacing = (-0.5).sp,
    ),
    displayMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 36.sp,
        lineHeight = 42.sp,
    ),
    headlineLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 30.sp,
        lineHeight = 36.sp,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 26.sp,
        lineHeight = 32.sp,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 18.sp,
        lineHeight = 24.sp,
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
        letterSpacing = 0.1.sp,
    ),
    titleSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.3.sp,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.2.sp,
    ),
    bodySmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.2.sp,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.1.sp,
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.4.sp,
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.4.sp,
    ),
)

private val MaxStreamShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(24.dp),
)

/**
 * Spacing scale. Use these instead of magic dp literals so gutters and
 * vertical rhythm stay consistent (the codebase had 20dp vs 24dp gutters and
 * 6/10/14/16/18/20/22/24dp one-off spacers).
 */
object AppSpacing {
    val xs = 4.dp
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val gutter = 20.dp // page/content horizontal padding
    val xl = 24.dp
    val xxl = 32.dp
}

/** Extra brand/data colors that don't belong in the Material color scheme. */
object AppColors {
    val ratingGold = Color(0xFFF5C518)
    val seriesBadge = Color(0xFF6366F1)
    val movieBadge = Color(0xFF2563EB)
    val success = Color(0xFF4ADE80)
    val warning = Color(0xFFFFB74D)

    /** Legible error red for text on photo/glass surfaces (scheme.error is too dark there). */
    val errorBright = Color(0xFFFF6B6B)
}

@Composable
fun DesktopTheme(
    useDarkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (useDarkTheme) DarkColors else LightColors,
        typography = MaxStreamTypography,
        shapes = MaxStreamShapes,
        content = content,
    )
}
