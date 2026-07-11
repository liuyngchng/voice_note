package com.voicenote.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.navigation.compose.rememberNavController
import com.voicenote.app.ui.navigation.NavGraph
import com.voicenote.app.ui.theme.VoiceNoteTheme
import dagger.hilt.android.AndroidEntryPoint
import java.io.File

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ -> }

    private var activeRecordId: Long = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Restore from saved instance state (fast path for Activity recreation)
        activeRecordId = savedInstanceState?.getLong(KEY_ACTIVE_RECORD_ID, 0) ?: 0

        // Fallback: check disk marker for process-death recovery
        if (activeRecordId == 0L) {
            activeRecordId = readActiveRecordingMarker()
        }

        requestPermissions()
        enableEdgeToEdge()
        setContent {
            VoiceNoteTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val navController = rememberNavController()
                    NavGraph(
                        navController = navController,
                        initialRecordId = activeRecordId
                    )
                }
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (activeRecordId > 0) {
            outState.putLong(KEY_ACTIVE_RECORD_ID, activeRecordId)
        }
    }

    private fun readActiveRecordingMarker(): Long {
        return try {
            val file = File(filesDir, ACTIVE_RECORDING_FILE)
            if (file.exists()) file.readText().trim().toLongOrNull() ?: 0L else 0L
        } catch (_: Exception) {
            0L
        }
    }

    private fun requestPermissions() {
        val needed = listOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.POST_NOTIFICATIONS
        ).filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (needed.isNotEmpty()) {
            permissionLauncher.launch(needed.toTypedArray())
        }
    }

    companion object {
        private const val ACTIVE_RECORDING_FILE = "active_recording.txt"
        private const val KEY_ACTIVE_RECORD_ID = "active_record_id"
    }
}
