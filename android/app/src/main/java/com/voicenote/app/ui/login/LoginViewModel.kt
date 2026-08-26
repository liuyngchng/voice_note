package com.voicenote.app.ui.login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voicenote.app.core.di.SettingsDataStore
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.util.UUID
import javax.inject.Inject

data class LoginUiState(
    val username: String = "",
    val password: String = "",
    val isLoggingIn: Boolean = false,
    val error: String? = null,
    val isAlreadyLoggedIn: Boolean = false,
    val loggedInUsername: String = "",
    val loginSuccess: Boolean = false
)

@HiltViewModel
class LoginViewModel @Inject constructor(
    private val settingsDataStore: SettingsDataStore
) : ViewModel() {

    private val _uiState = MutableStateFlow(LoginUiState())
    val uiState: StateFlow<LoginUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            val settings = settingsDataStore.settingsFlow.first()
            if (settings.authToken.isNotBlank()) {
                _uiState.value = _uiState.value.copy(
                    isAlreadyLoggedIn = true,
                    loggedInUsername = settings.username
                )
            }
        }
    }

    fun updateUsername(value: String) {
        _uiState.value = _uiState.value.copy(username = value, error = null)
    }

    fun updatePassword(value: String) {
        _uiState.value = _uiState.value.copy(password = value, error = null)
    }

    fun login() {
        val username = _uiState.value.username.trim()
        val password = _uiState.value.password.trim()

        if (username.isEmpty()) {
            _uiState.value = _uiState.value.copy(error = "请输入用户名")
            return
        }
        if (password.isEmpty()) {
            _uiState.value = _uiState.value.copy(error = "请输入密码")
            return
        }

        _uiState.value = _uiState.value.copy(isLoggingIn = true, error = null)

        viewModelScope.launch {
            try {
                // 模拟登录：生成一个假 token
                val fakeToken = UUID.randomUUID().toString()
                settingsDataStore.updateAuth(fakeToken, username)
                _uiState.value = _uiState.value.copy(isLoggingIn = false, loginSuccess = true)
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoggingIn = false,
                    error = e.message ?: "登录失败"
                )
            }
        }
    }

    fun skipLogin() {
        // 跳过登录，直接进入主页
    }
}