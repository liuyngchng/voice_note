// Package llm provides an OpenAI-compatible chat completions client
// for generating structured meeting summaries from transcripts.
package llm

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"
)

// Config holds the LLM API configuration.
type Config struct {
	APIEndpoint string
	APIKey      string
	ModelName   string
}

// IsValid returns true if the config has both endpoint and key set.
func (c Config) IsValid() bool {
	return c.APIEndpoint != "" && c.APIKey != ""
}

// Client wraps the OpenAI-compatible API for meeting summarization.
type Client struct {
	httpClient *http.Client
}

// NewClient creates a new LLM client.
func NewClient() *Client {
	return &Client{
		httpClient: &http.Client{Timeout: 120 * time.Second},
	}
}

const maxChunkChars = 8000

// GenerateSummary produces a structured meeting summary from a transcript.
// Long transcripts are automatically split into chunks, summarized individually,
// and merged. progress is an optional callback for UI status updates.
func (c *Client) GenerateSummary(transcript string, config Config, progress func(string)) (*RecordSummary, error) {
	if !config.IsValid() {
		return nil, fmt.Errorf("LLM 配置不完整，请在设置中配置 API 地址和密钥")
	}

	if len(transcript) <= maxChunkChars {
		if progress != nil {
			progress("正在请求 AI 总结...")
		}
		return c.singlePass(transcript, config)
	}
	return c.multiPass(transcript, config, progress)
}

// TestConnection sends a minimal request to verify API connectivity.
func (c *Client) TestConnection(config Config) error {
	if !config.IsValid() {
		return fmt.Errorf("API 地址或密钥未配置")
	}

	reqBody := map[string]interface{}{
		"model": config.ModelName,
		"messages": []map[string]string{
			{"role": "user", "content": "你好，请回复'连接成功'"},
		},
		"max_tokens": 20,
	}

	resp, err := c.callAPI(config, reqBody)
	if err != nil {
		return fmt.Errorf("连接失败: %w", err)
	}

	content, err := extractContent(resp)
	if err != nil {
		return fmt.Errorf("解析响应失败: %w", err)
	}

	slog.Info("llm_test_connection_ok", "content", content)
	return nil
}

// ---- Single-pass ----

func (c *Client) singlePass(transcript string, config Config) (*RecordSummary, error) {
	systemPrompt := summarySystemPrompt()
	userPrompt := "以下是会议转写内容，请总结：\n\n" + transcript

	reqBody := map[string]interface{}{
		"model": config.ModelName,
		"messages": []map[string]string{
			{"role": "system", "content": systemPrompt},
			{"role": "user", "content": userPrompt},
		},
		"temperature": 0.3,
		"max_tokens":  2048,
	}

	resp, err := c.callAPI(config, reqBody)
	if err != nil {
		return nil, err
	}

	content, err := extractContent(resp)
	if err != nil {
		return nil, err
	}
	return parseSummary(content)
}

// ---- Multi-pass ----

func (c *Client) multiPass(transcript string, config Config, progress func(string)) (*RecordSummary, error) {
	chunks := splitText(transcript, maxChunkChars)
	total := len(chunks)
	slog.Info("llm_multi_pass", "chars", len(transcript), "chunks", total)

	var chunkSummaries []string
	for i, chunk := range chunks {
		if progress != nil {
			progress(fmt.Sprintf("正在分析片段 (%d/%d)...", i+1, total))
		}

		chunkPrompt := "用一两句话提取以下文本的关键信息，不要遗漏重要事项和决定：\n\n" + chunk
		reqBody := map[string]interface{}{
			"model": config.ModelName,
			"messages": []map[string]string{
				{"role": "user", "content": chunkPrompt},
			},
			"temperature": 0.3,
			"max_tokens":  256,
		}

		resp, err := c.callAPIWithRetry(config, reqBody, 3)
		if err != nil {
			slog.Warn("llm_chunk_failed", "chunk", i+1, "error", err)
			continue
		}
		text, err := extractContent(resp)
		if err == nil && strings.TrimSpace(text) != "" {
			chunkSummaries = append(chunkSummaries, strings.TrimSpace(text))
		}
	}

	if len(chunkSummaries) == 0 {
		return nil, fmt.Errorf("所有分段摘要均失败")
	}

	if progress != nil {
		progress("正在整合摘要...")
	}

	var mergedText string
	if len(chunkSummaries) == 1 {
		mergedText = chunkSummaries[0]
	} else {
		var sb strings.Builder
		for i, s := range chunkSummaries {
			sb.WriteString(fmt.Sprintf("【片段 %d】%s\n\n", i+1, s))
		}
		mergePrompt := "以下是从长文本中提取的分段摘要，请整合为一个连贯的总结：\n\n" + sb.String()

		systemPrompt := summarySystemPrompt()
		reqBody := map[string]interface{}{
			"model": config.ModelName,
			"messages": []map[string]string{
				{"role": "system", "content": systemPrompt},
				{"role": "user", "content": mergePrompt},
			},
			"temperature": 0.3,
			"max_tokens":  2048,
		}
		resp, err := c.callAPIWithRetry(config, reqBody, 3)
		if err != nil {
			return nil, err
		}
		mergedText, err = extractContent(resp)
		if err != nil {
			return nil, err
		}
	}

	return parseSummary(mergedText)
}

// ---- API helpers ----

func buildURL(endpoint string) string {
	trimmed := strings.TrimRight(endpoint, "/")
	if strings.HasSuffix(trimmed, "/chat/completions") {
		return trimmed
	}
	return trimmed + "/v1/chat/completions"
}

func (c *Client) callAPIWithRetry(config Config, body map[string]interface{}, maxRetries int) (*http.Response, error) {
	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		resp, err := c.callAPI(config, body)
		if err == nil {
			return resp, nil
		}
		lastErr = err
		if attempt < maxRetries-1 {
			waitMs := int64(math.Pow(2, float64(attempt)) * 1000)
			slog.Warn("llm_retry", "attempt", attempt+1, "wait_ms", waitMs, "error", err)
			time.Sleep(time.Duration(waitMs) * time.Millisecond)
		}
	}
	return nil, lastErr
}

func (c *Client) callAPI(config Config, body map[string]interface{}) (*http.Response, error) {
	jsonBody, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	url := buildURL(config.APIEndpoint)
	req, err := http.NewRequest("POST", url, strings.NewReader(string(jsonBody)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+config.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("API 请求失败: %w", err)
	}

	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		var errResp struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&errResp)
		msg := errResp.Error.Message
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		return nil, fmt.Errorf("API 请求失败: %s", msg)
	}

	return resp, nil
}

func extractContent(resp *http.Response) (string, error) {
	defer resp.Body.Close()
	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("解析 API 响应失败: %w", err)
	}
	if len(result.Choices) == 0 {
		return "", fmt.Errorf("响应 choices 为空")
	}
	return result.Choices[0].Message.Content, nil
}

// ---- JSON parsing ----

// RecordSummary is the structured meeting summary.
type RecordSummary struct {
	Topics      []string   `json:"topics"`
	Conclusions []string   `json:"conclusions"`
	Todos       []TodoItem `json:"todos"`
	NextSteps   []string   `json:"next_steps"`
}

// TodoItem is an action item.
type TodoItem struct {
	ID       string `json:"id"`
	Task     string `json:"task"`
	Owner    string `json:"owner"`
	Deadline string `json:"deadline"`
}

func parseSummary(content string) (*RecordSummary, error) {
	jsonStr := extractJSON(content)
	var summary RecordSummary
	if err := json.Unmarshal([]byte(jsonStr), &summary); err != nil {
		return nil, fmt.Errorf("解析总结结果失败: %w", err)
	}
	slog.Info("llm_summary_parsed",
		"topics", len(summary.Topics),
		"conclusions", len(summary.Conclusions),
		"todos", len(summary.Todos),
		"nextSteps", len(summary.NextSteps))
	return &summary, nil
}

func extractJSON(content string) string {
	trimmed := strings.TrimSpace(content)
	// Try ```json ... ``` code block.
	if idx := strings.Index(trimmed, "```json"); idx >= 0 {
		start := idx + 7
		if end := strings.Index(trimmed[start:], "```"); end >= 0 {
			return strings.TrimSpace(trimmed[start : start+end])
		}
	}
	if idx := strings.Index(trimmed, "```"); idx >= 0 {
		start := idx + 3
		if end := strings.Index(trimmed[start:], "```"); end >= 0 {
			return strings.TrimSpace(trimmed[start : start+end])
		}
	}
	// Try raw { ... }.
	firstBrace := strings.Index(trimmed, "{")
	lastBrace := strings.LastIndex(trimmed, "}")
	if firstBrace >= 0 && lastBrace > firstBrace {
		return trimmed[firstBrace : lastBrace+1]
	}
	return trimmed
}

// ---- Prompt ----

func summarySystemPrompt() string {
	return `你是一个专业的会议记录总结助手。请从以下会议转写文本中提取关键信息，以 JSON 格式返回。
JSON 格式要求：
{
  "topics": ["议题1", "议题2"],
  "conclusions": ["结论1", "结论2"],
  "todos": [{"task": "待办事项", "owner": "负责人", "deadline": "截止时间"}],
  "nextSteps": ["后续步骤1", "后续步骤2"]
}
注意：
1. 只返回 JSON，不要包含任何其他文字
2. 如果某个字段没有相关内容，返回空数组 []
3. todos 中的 owner 和 deadline 如果未提及则为空字符串
4. 请确保 JSON 格式正确，可以被直接解析`
}

// ---- Text splitting ----

func splitText(text string, maxChars int) []string {
	if len(text) <= maxChars {
		return []string{text}
	}
	sentences := splitBySentences(text)

	var chunks []string
	var currentChunk strings.Builder

	for _, sentence := range sentences {
		if len(sentence) > maxChars {
			if currentChunk.Len() > 0 {
				chunks = append(chunks, strings.TrimSpace(currentChunk.String()))
				currentChunk.Reset()
			}
			remaining := sentence
			for len(remaining) > maxChars {
				chunks = append(chunks, strings.TrimSpace(remaining[:maxChars]))
				remaining = remaining[maxChars:]
			}
			if len(remaining) > 0 {
				currentChunk.WriteString(remaining)
			}
			continue
		}

		if currentChunk.Len()+len(sentence) > maxChars {
			if currentChunk.Len() > 0 {
				chunks = append(chunks, strings.TrimSpace(currentChunk.String()))
				currentChunk.Reset()
			}
		}
		currentChunk.WriteString(sentence)
	}

	if currentChunk.Len() > 0 {
		chunks = append(chunks, strings.TrimSpace(currentChunk.String()))
	}
	if len(chunks) == 0 {
		return []string{text}
	}
	return chunks
}

func splitBySentences(text string) []string {
	// Simple sentence splitting on common Chinese/English punctuation.
	delimPattern := func(r rune) bool {
		switch r {
		case '。', '！', '？', '!', '?', '\n':
			return true
		}
		return false
	}

	var sentences []string
	start := 0
	runes := []rune(text)
	for i, r := range runes {
		if delimPattern(r) {
			sent := strings.TrimSpace(string(runes[start : i+1]))
			if sent != "" {
				sentences = append(sentences, sent)
			}
			start = i + 1
		}
	}
	if start < len(runes) {
		sent := strings.TrimSpace(string(runes[start:]))
		if sent != "" {
			sentences = append(sentences, sent)
		}
	}
	if len(sentences) == 0 {
		return []string{text}
	}
	return sentences
}