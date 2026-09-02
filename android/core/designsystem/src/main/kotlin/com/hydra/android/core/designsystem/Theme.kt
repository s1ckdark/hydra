package com.hydra.android.core.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val DarkColors = darkColorScheme(primary = HydraBlue, tertiary = HydraPurple)
private val LightColors = lightColorScheme(primary = HydraBlue, tertiary = HydraPurple)

/**
 * Dynamic color is deliberately not used: the dashboard encodes meaning in the
 * four accent colors, and Material You would repaint them per wallpaper.
 */
@Composable
fun HydraTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
