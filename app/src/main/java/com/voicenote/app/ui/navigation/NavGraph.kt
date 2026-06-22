package com.voicenote.app.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.voicenote.app.ui.detail.DetailScreen
import com.voicenote.app.ui.history.HistoryScreen
import com.voicenote.app.ui.home.HomeScreen
import com.voicenote.app.ui.recording.RecordingScreen
import com.voicenote.app.ui.settings.SettingsScreen

object Routes {
    const val HOME = "home"
    const val RECORDING = "recording"
    const val DETAIL = "detail/{recordId}"
    const val HISTORY = "history"
    const val SETTINGS = "settings"

    fun detail(recordId: Long) = "detail/$recordId"
}

@Composable
fun NavGraph(navController: NavHostController) {
    NavHost(navController = navController, startDestination = Routes.HOME) {
        composable(Routes.HOME) {
            HomeScreen(
                onStartRecording = { navController.navigate(Routes.RECORDING) },
                onRecordClick = { id -> navController.navigate(Routes.detail(id)) },
                onHistoryClick = { navController.navigate(Routes.HISTORY) },
                onSettingsClick = { navController.navigate(Routes.SETTINGS) }
            )
        }

        composable(Routes.RECORDING) {
            RecordingScreen(
                onBack = { navController.popBackStack() },
                onRecordComplete = { _ ->
                    navController.navigate(Routes.HOME) {
                        popUpTo(Routes.RECORDING) { inclusive = true }
                    }
                }
            )
        }

        composable(
            route = Routes.DETAIL,
            arguments = listOf(navArgument("recordId") { type = NavType.LongType })
        ) { backStackEntry ->
            val recordId = backStackEntry.arguments?.getLong("recordId") ?: return@composable
            DetailScreen(
                recordId = recordId,
                onBack = { navController.popBackStack() }
            )
        }

        composable(Routes.HISTORY) {
            HistoryScreen(
                onBack = { navController.popBackStack() },
                onRecordClick = { id -> navController.navigate(Routes.detail(id)) }
            )
        }

        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}
