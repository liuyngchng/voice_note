package com.smartbadge.app.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.smartbadge.app.ui.detail.DetailScreen
import com.smartbadge.app.ui.history.HistoryScreen
import com.smartbadge.app.ui.home.HomeScreen
import com.smartbadge.app.ui.recording.RecordingScreen
import com.smartbadge.app.ui.settings.SettingsScreen

object Routes {
    const val HOME = "home"
    const val RECORDING = "recording"
    const val DETAIL = "detail/{visitId}"
    const val HISTORY = "history"
    const val SETTINGS = "settings"

    fun detail(visitId: Long) = "detail/$visitId"
}

@Composable
fun NavGraph(navController: NavHostController) {
    NavHost(navController = navController, startDestination = Routes.HOME) {
        composable(Routes.HOME) {
            HomeScreen(
                onStartVisit = { navController.navigate(Routes.RECORDING) },
                onVisitClick = { id -> navController.navigate(Routes.detail(id)) },
                onHistoryClick = { navController.navigate(Routes.HISTORY) },
                onSettingsClick = { navController.navigate(Routes.SETTINGS) }
            )
        }

        composable(Routes.RECORDING) {
            RecordingScreen(
                onBack = { navController.popBackStack() },
                onVisitComplete = { visitId ->
                    navController.popBackStack()
                    navController.navigate(Routes.detail(visitId))
                }
            )
        }

        composable(
            route = Routes.DETAIL,
            arguments = listOf(navArgument("visitId") { type = NavType.LongType })
        ) { backStackEntry ->
            val visitId = backStackEntry.arguments?.getLong("visitId") ?: return@composable
            DetailScreen(
                visitId = visitId,
                onBack = { navController.popBackStack() }
            )
        }

        composable(Routes.HISTORY) {
            HistoryScreen(
                onBack = { navController.popBackStack() },
                onVisitClick = { id -> navController.navigate(Routes.detail(id)) }
            )
        }

        composable(Routes.SETTINGS) {
            SettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}
