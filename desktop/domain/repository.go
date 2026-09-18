// Package domain defines the core data models and repository interface
// for the voice note application.
package domain

import "context"

// VoiceRecordRepository defines the data access contract for voice records.
// Implementations are in package data.
type VoiceRecordRepository interface {
	// GetAll returns all records ordered by start time descending.
	GetAll(ctx context.Context) ([]VoiceRecord, error)

	// Search returns records matching the query in title, memo, or description.
	Search(ctx context.Context, query string) ([]VoiceRecord, error)

	// GetByDateRange returns records within the given time range (epoch millis).
	GetByDateRange(ctx context.Context, fromEpochMillis, toEpochMillis int64) ([]VoiceRecord, error)

	// GetByID returns a single record or nil if not found.
	GetByID(ctx context.Context, id int64) (*VoiceRecord, error)

	// Create inserts a new record and returns the generated ID.
	Create(ctx context.Context, record VoiceRecord) (int64, error)

	// Update modifies an existing record.
	Update(ctx context.Context, record VoiceRecord) error

	// UpdateTranscriptWithFile updates the transcript file path for a record.
	UpdateTranscriptWithFile(ctx context.Context, id int64, transcriptFilePath string) error

	// UpdateTranscriptStatus changes the transcript processing status.
	UpdateTranscriptStatus(ctx context.Context, id int64, status ProcessingStatus) error

	// UpdateStartTime sets the recording start time.
	UpdateStartTime(ctx context.Context, id int64, startTime int64) error

	// UpdateAudioFilePath sets the audio file path and end time.
	UpdateAudioFilePath(ctx context.Context, id int64, path string, endTime int64) error

	// Delete removes a record by ID.
	Delete(ctx context.Context, id int64) error

	// GetAllTitles returns distinct titles for autocomplete suggestions.
	GetAllTitles(ctx context.Context) ([]string, error)

	// UpdateSummary persists the AI-generated summary.
	UpdateSummary(ctx context.Context, id int64, summary RecordSummary) error

	// UpdateSummaryStatus changes the summary processing status.
	UpdateSummaryStatus(ctx context.Context, id int64, status ProcessingStatus) error

	// UpdateServerRecordID sets the server-assigned record ID.
	UpdateServerRecordID(ctx context.Context, id int64, serverRecordID string) error
}