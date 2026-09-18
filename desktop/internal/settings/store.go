// Package settings provides JSON-file-based configuration persistence.
// Replaces Android's DataStore Preferences.
package settings

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// AppSettings holds all runtime configuration.
type AppSettings struct {
	OfflineModelQuality string `json:"offline_model_quality"`
	LLMAPIEendpoint     string `json:"llm_api_endpoint"`
	LLMAPIKey           string `json:"llm_api_key"`
	LLMModelName        string `json:"llm_model_name"`
	ServerURI           string `json:"server_uri"`
	AuthToken           string `json:"auth_token"`
	Username            string `json:"username"`
	Password            string `json:"password"`
}

// DefaultAppSettings returns the factory defaults.
func DefaultAppSettings() AppSettings {
	return AppSettings{
		OfflineModelQuality: "int8",
		LLMAPIEendpoint:     "https://api.deepseek.com",
		LLMAPIKey:           "",
		LLMModelName:        "deepseek-v4-flash",
		ServerURI:           "http://192.168.1.110:8080",
	}
}

// Store persists AppSettings to a JSON file on disk.
type Store struct {
	mu       sync.RWMutex
	path     string
	settings AppSettings
}

// LoadStore reads settings from dataDir/settings.json, creating defaults if
// the file does not exist.
func LoadStore(dataDir string) (*Store, error) {
	s := &Store{
		path:     filepath.Join(dataDir, "settings.json"),
		settings: DefaultAppSettings(),
	}
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, fmt.Errorf("settings: create dir: %w", err)
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			// Write defaults so the file exists on first launch.
			if err := s.flush(); err != nil {
				return nil, err
			}
			return s, nil
		}
		return nil, fmt.Errorf("settings: read: %w", err)
	}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &s.settings); err != nil {
			return nil, fmt.Errorf("settings: unmarshal: %w", err)
		}
	}
	return s, nil
}

// Get returns a copy of the current settings.
func (s *Store) Get() AppSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.settings
}

// UpdateOfflineModelQuality persists the model quality preference.
func (s *Store) UpdateOfflineModelQuality(quality string) error {
	s.mu.Lock()
	s.settings.OfflineModelQuality = quality
	s.mu.Unlock()
	return s.flush()
}

// UpdateLLMConfig persists the LLM API configuration.
func (s *Store) UpdateLLMConfig(endpoint, apiKey, modelName string) error {
	s.mu.Lock()
	s.settings.LLMAPIEendpoint = endpoint
	s.settings.LLMAPIKey = apiKey
	s.settings.LLMModelName = modelName
	s.mu.Unlock()
	return s.flush()
}

// UpdateServerURI persists the server address.
func (s *Store) UpdateServerURI(uri string) error {
	s.mu.Lock()
	s.settings.ServerURI = uri
	s.mu.Unlock()
	return s.flush()
}

// UpdateAuth persists login credentials.
func (s *Store) UpdateAuth(token, username, password string) error {
	s.mu.Lock()
	s.settings.AuthToken = token
	s.settings.Username = username
	s.settings.Password = password
	s.mu.Unlock()
	return s.flush()
}

// ClearAuth removes login credentials.
func (s *Store) ClearAuth() error {
	s.mu.Lock()
	s.settings.AuthToken = ""
	s.settings.Username = ""
	s.settings.Password = ""
	s.mu.Unlock()
	return s.flush()
}

// IsLoggedIn returns true when a valid auth token is present.
func (s *Store) IsLoggedIn() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.settings.AuthToken != ""
}

func (s *Store) flush() error {
	// Re-read under the lock to avoid TOCTOU.
	data, err := json.MarshalIndent(s.settings, "", "  ")
	if err != nil {
		return fmt.Errorf("settings: marshal: %w", err)
	}
	if err := os.WriteFile(s.path, data, 0600); err != nil {
		return fmt.Errorf("settings: write: %w", err)
	}
	return nil
}