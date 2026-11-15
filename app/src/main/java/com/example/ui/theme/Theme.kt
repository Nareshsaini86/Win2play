package com.example.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

private val DarkColorScheme =
  darkColorScheme(
    primary = PlayGold,
    onPrimary = OnGold,
    secondary = PlayViolet,
    tertiary = PlayAmber,
    background = MidnightNavy,
    onBackground = MidnightInk,
    surface = MidnightSurface,
    onSurface = MidnightInk,
    error = PlayRed,
  )

private val LightColorScheme =
  lightColorScheme(
    primary = DayAmber,
    onPrimary = OnGold,
    secondary = DayViolet,
    tertiary = PlayGold,
    background = DayBackground,
    onBackground = DayInk,
    surface = DaySurface,
    onSurface = DayInk,
  )

@Composable
fun MyApplicationTheme(
  darkTheme: Boolean = isSystemInDarkTheme(),
  dynamicColor: Boolean = false,
  content: @Composable () -> Unit,
) {
  val colorScheme =
    when {
      dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
        val context = LocalContext.current
        if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
      }
      darkTheme -> DarkColorScheme
      else -> LightColorScheme
    }

  MaterialTheme(colorScheme = colorScheme, typography = Typography, content = content)
}
