// Package network provides the HTTP client for uploading audio to the server.
package network

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/liuyngchng/voice-note-desktop/domain"
)

// UploadResult contains the server response from an upload.
type UploadResult struct {
	ServerRecordID string `json:"server_record_id"`
	Message        string `json:"message"`
}

// ServerClient handles authentication and audio upload to the server.
type ServerClient struct {
	httpClient  *http.Client
	cachedToken string
	username    string
	password    string
}

// NewServerClient creates a new ServerClient with saved credentials.
func NewServerClient(username, password string) *ServerClient {
	return &ServerClient{
		httpClient: &http.Client{Timeout: 120 * time.Second},
		username:   username,
		password:   password,
	}
}

// UpdateCredentials refreshes the stored login credentials.
func (c *ServerClient) UpdateCredentials(username, password string) {
	c.username = username
	c.password = password
	c.cachedToken = ""
}

// UploadAudio uploads an audio file to the server.
func (c *ServerClient) UploadAudio(audioFilePath string, record domain.VoiceRecord, serverURI string, progress func(string)) (*UploadResult, error) {
	if serverURI == "" {
		return nil, fmt.Errorf("服务器地址未配置")
	}

	// 1. Ensure logged in.
	if progress != nil {
		progress("正在连接服务器...")
	}
	token, err := c.ensureLoggedIn(serverURI)
	if err != nil {
		return nil, fmt.Errorf("服务器登录失败: %w", err)
	}

	// 2. Upload audio.
	if progress != nil {
		progress("正在上传音频...")
	}
	return c.doUpload(serverURI, token, audioFilePath, record)
}

// ---- Login ----

func (c *ServerClient) ensureLoggedIn(serverURI string) (string, error) {
	if c.cachedToken != "" {
		return c.cachedToken, nil
	}
	if c.username == "" || c.password == "" {
		return "", fmt.Errorf("未登录或凭证为空，无法上传到服务器")
	}

	loginURL := normalizeURL(serverURI) + "/api/auth/login"
	body := map[string]string{
		"username": c.username,
		"password": c.password,
	}
	jsonBody, err := json.Marshal(body)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequest("POST", loginURL, strings.NewReader(string(jsonBody)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("登录失败: HTTP %d", resp.StatusCode)
	}

	var result struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.Token != "" {
		c.cachedToken = result.Token
		slog.Info("server_login_success")
	}
	return result.Token, nil
}

// ---- Upload ----

func (c *ServerClient) doUpload(serverURI, token, audioFilePath string, record domain.VoiceRecord) (*UploadResult, error) {
	uploadURL := normalizeURL(serverURI) + "/api/records"

	// Generate business ID.
	businessID := generateBusinessID()

	// Build metadata.
	inspectorName := "用户"
	if len(record.Speakers) > 0 {
		inspectorName = record.Speakers[0]
	}
	metadata := map[string]string{
		"id":               businessID,
		"title":            record.Title,
		"description":      record.Description,
		"inspector_name":   inspectorName,
		"customer_name":    "未知",
		"customer_address": "",
		"inspection_date":  time.Now().Format(time.RFC3339),
		"source_type":      record.SourceType,
	}
	metadataJSON, err := json.Marshal(metadata)
	if err != nil {
		return nil, err
	}

	// Build multipart form.
	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)

	// metadata part.
	mp, _ := writer.CreateFormField("metadata")
	mp.Write(metadataJSON)

	// audio part.
	audioFile, err := readAudioFile(audioFilePath)
	if err != nil {
		return nil, fmt.Errorf("读取音频文件失败: %w", err)
	}
	mimeType := "audio/wav"
	if strings.HasSuffix(strings.ToLower(audioFilePath), ".mp3") {
		mimeType = "audio/mpeg"
	} else if strings.HasSuffix(strings.ToLower(audioFilePath), ".m4a") {
		mimeType = "audio/mp4"
	}
	fileName := filepath.Base(audioFilePath)
	header := textproto.MIMEHeader{}
	header.Set("Content-Disposition",
		fmt.Sprintf(`form-data; name="audio"; filename="%s"`, fileName))
	header.Set("Content-Type", mimeType)
	part, err := writer.CreatePart(header)
	if err != nil {
		return nil, err
	}
	part.Write(audioFile)
	writer.Close()

	req, err := http.NewRequest("POST", uploadURL, &buf)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("上传失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		bodyBytes, _ := io.ReadAll(resp.Body)
		var errResp struct {
			Error string `json:"error"`
		}
		json.Unmarshal(bodyBytes, &errResp)
		msg := errResp.Error
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		if resp.StatusCode == 401 {
			c.cachedToken = ""
		}
		return nil, fmt.Errorf("上传失败: %s", msg)
	}

	slog.Info("server_upload_success", "business_id", businessID)
	return &UploadResult{
		ServerRecordID: businessID,
		Message:        "上传成功，服务器正在后台转写...",
	}, nil
}

// ---- Helpers ----

func generateBusinessID() string {
	now := time.Now()
	return now.Format("20060102150405") + fmt.Sprintf("%03d", now.UnixMilli()%1000)
}

func normalizeURL(uri string) string {
	trimmed := strings.TrimRight(uri, "/")
	if strings.HasPrefix(trimmed, "http://") || strings.HasPrefix(trimmed, "https://") {
		return trimmed
	}
	return "http://" + trimmed
}

func readAudioFile(path string) ([]byte, error) {
	return readFileDirect(path)
}

func readFileDirect(path string) ([]byte, error) {
	file, err := openFile(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return io.ReadAll(file)
}

// openFile is a platform-independent file opener (for use in multipart uploads).
func openFile(path string) (io.ReadCloser, error) {
	return os.Open(path)
}
