// Package domain defines the core data models and repository interface
// for the voice note application.
package domain

import "time"

// ProcessingStatus represents the current state of transcript/summary processing.
type ProcessingStatus string

const (
	StatusPending     ProcessingStatus = "PENDING"
	StatusProcessing  ProcessingStatus = "PROCESSING"
	StatusCompleted   ProcessingStatus = "COMPLETED"
	StatusUnavailable ProcessingStatus = "UNAVAILABLE"
)

// VoiceRecord represents a single voice recording with its metadata.
type VoiceRecord struct {
	ID                 int64            `json:"id"`
	Title              string           `json:"title"`
	Memo               string           `json:"memo"`
	Description        string           `json:"description"`
	Speakers           []string         `json:"speakers"`
	SourceType         string           `json:"source_type"`
	StartTime          time.Time        `json:"start_time"`
	EndTime            *time.Time       `json:"end_time,omitempty"`
	TranscriptStatus   ProcessingStatus `json:"transcript_status"`
	AudioFilePath      string           `json:"audio_file_path"`
	TranscriptFilePath string           `json:"transcript_file_path"`
	CreatedAt          time.Time        `json:"created_at"`
	// AI summary (online LLM)
	SummaryStatus      ProcessingStatus `json:"summary_status"`
	Summary            *RecordSummary   `json:"summary,omitempty"`
	SummaryGeneratedAt *time.Time       `json:"summary_generated_at,omitempty"`
	// Server upload record ID (non-empty means uploaded)
	ServerRecordID string `json:"server_record_id"`
}

// RecordSummary is the AI-generated meeting summary.
type RecordSummary struct {
	Topics      []string   `json:"topics"`
	Conclusions []string   `json:"conclusions"`
	Todos       []TodoItem `json:"todos"`
	NextSteps   []string   `json:"next_steps"`
}

// IsEmpty returns true if the summary contains no meaningful content.
func (s *RecordSummary) IsEmpty() bool {
	return len(s.Topics) == 0 && len(s.Conclusions) == 0 &&
		len(s.Todos) == 0 && len(s.NextSteps) == 0
}

// TodoItem represents an action item extracted from a meeting.
type TodoItem struct {
	ID       string `json:"id"`
	Task     string `json:"task"`
	Owner    string `json:"owner"`
	Deadline string `json:"deadline"`
}
