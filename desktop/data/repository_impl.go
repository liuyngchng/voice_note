// Package data implements the domain repository using SQLite.
package data

import (
	"context"
	"encoding/json"
	"time"

	"github.com/liuyngchng/voice-note-desktop/domain"
	"github.com/liuyngchng/voice-note-desktop/internal/database"
)

// Repository implements domain.VoiceRecordRepository backed by SQLite.
type Repository struct {
	dao *database.RecordDAO
}

// NewRepository creates a new Repository.
func NewRepository(dao *database.RecordDAO) *Repository {
	return &Repository{dao: dao}
}

// ---- Query ----

func (r *Repository) GetAll(ctx context.Context) ([]domain.VoiceRecord, error) {
	rows, err := r.dao.GetAll(ctx)
	if err != nil {
		return nil, err
	}
	return mapRows(rows), nil
}

func (r *Repository) Search(ctx context.Context, query string) ([]domain.VoiceRecord, error) {
	rows, err := r.dao.Search(ctx, query)
	if err != nil {
		return nil, err
	}
	return mapRows(rows), nil
}

func (r *Repository) GetByDateRange(ctx context.Context, from, to int64) ([]domain.VoiceRecord, error) {
	rows, err := r.dao.GetByDateRange(ctx, from, to)
	if err != nil {
		return nil, err
	}
	return mapRows(rows), nil
}

func (r *Repository) GetByID(ctx context.Context, id int64) (*domain.VoiceRecord, error) {
	row, err := r.dao.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, nil
	}
	v := rowToDomain(*row)
	return &v, nil
}

// ---- Mutation ----

func (r *Repository) Create(ctx context.Context, record domain.VoiceRecord) (int64, error) {
	row := domainToRow(record)
	return r.dao.Insert(ctx, &row)
}

func (r *Repository) Update(ctx context.Context, record domain.VoiceRecord) error {
	row := domainToRow(record)
	row.ID = record.ID
	return r.dao.Update(ctx, &row)
}

func (r *Repository) UpdateTranscriptWithFile(ctx context.Context, id int64, path string) error {
	existing, err := r.dao.GetByID(ctx, id)
	if err != nil || existing == nil {
		return err
	}
	existing.TranscriptFilePath = path
	return r.dao.Update(ctx, existing)
}

func (r *Repository) UpdateTranscriptStatus(ctx context.Context, id int64, status domain.ProcessingStatus) error {
	existing, err := r.dao.GetByID(ctx, id)
	if err != nil || existing == nil {
		return err
	}
	existing.TranscriptStatus = string(status)
	return r.dao.Update(ctx, existing)
}

func (r *Repository) UpdateStartTime(ctx context.Context, id int64, startTime int64) error {
	return r.dao.UpdateStartTime(ctx, id, startTime)
}

func (r *Repository) UpdateAudioFilePath(ctx context.Context, id int64, path string, endTime int64) error {
	existing, err := r.dao.GetByID(ctx, id)
	if err != nil || existing == nil {
		return err
	}
	existing.AudioFilePath = path
	existing.EndTime = &endTime
	return r.dao.Update(ctx, existing)
}

func (r *Repository) Delete(ctx context.Context, id int64) error {
	return r.dao.DeleteByID(ctx, id)
}

func (r *Repository) GetAllTitles(ctx context.Context) ([]string, error) {
	return r.dao.GetAllTitles(ctx)
}

func (r *Repository) UpdateSummary(ctx context.Context, id int64, summary domain.RecordSummary) error {
	data, err := json.Marshal(summary)
	if err != nil {
		return err
	}
	now := time.Now().UnixMilli()
	return r.dao.UpdateSummary(ctx, id, string(data), string(domain.StatusCompleted), &now)
}

func (r *Repository) UpdateSummaryStatus(ctx context.Context, id int64, status domain.ProcessingStatus) error {
	return r.dao.UpdateSummaryStatus(ctx, id, string(status))
}

func (r *Repository) UpdateServerRecordID(ctx context.Context, id int64, serverRecordID string) error {
	return r.dao.UpdateServerRecordID(ctx, id, serverRecordID)
}

// ---- Map helpers ----

func domainToRow(v domain.VoiceRecord) database.RecordRow {
	speakersJSON, _ := json.Marshal(v.Speakers)
	summaryJSON := ""
	if v.Summary != nil {
		b, _ := json.Marshal(v.Summary)
		summaryJSON = string(b)
	}
	var endTime *int64
	if v.EndTime != nil {
		t := v.EndTime.UnixMilli()
		endTime = &t
	}
	var summaryGeneratedAt *int64
	if v.SummaryGeneratedAt != nil {
		t := v.SummaryGeneratedAt.UnixMilli()
		summaryGeneratedAt = &t
	}
	return database.RecordRow{
		ID:                 v.ID,
		Title:              v.Title,
		Memo:               v.Memo,
		Description:        v.Description,
		SpeakersJSON:       string(speakersJSON),
		SourceType:         v.SourceType,
		StartTime:          v.StartTime.UnixMilli(),
		EndTime:            endTime,
		AudioFilePath:      v.AudioFilePath,
		TranscriptFilePath: v.TranscriptFilePath,
		TranscriptStatus:   string(v.TranscriptStatus),
		CreatedAt:          v.CreatedAt.UnixMilli(),
		SummaryJSON:        summaryJSON,
		SummaryStatus:      string(v.SummaryStatus),
		SummaryGeneratedAt: summaryGeneratedAt,
		ServerRecordID:     v.ServerRecordID,
	}
}

func rowToDomain(r database.RecordRow) domain.VoiceRecord {
	var speakers []string
	if r.SpeakersJSON != "" {
		json.Unmarshal([]byte(r.SpeakersJSON), &speakers)
	}
	var summary *domain.RecordSummary
	if r.SummaryJSON != "" {
		var s domain.RecordSummary
		if err := json.Unmarshal([]byte(r.SummaryJSON), &s); err == nil {
			summary = &s
		}
	}
	var endTime *time.Time
	if r.EndTime != nil {
		t := time.UnixMilli(*r.EndTime)
		endTime = &t
	}
	var summaryGeneratedAt *time.Time
	if r.SummaryGeneratedAt != nil {
		t := time.UnixMilli(*r.SummaryGeneratedAt)
		summaryGeneratedAt = &t
	}
	return domain.VoiceRecord{
		ID:                 r.ID,
		Title:              r.Title,
		Memo:               r.Memo,
		Description:        r.Description,
		Speakers:           speakers,
		SourceType:         r.SourceType,
		StartTime:          time.UnixMilli(r.StartTime),
		EndTime:            endTime,
		TranscriptStatus:   domain.ProcessingStatus(r.TranscriptStatus),
		AudioFilePath:      r.AudioFilePath,
		TranscriptFilePath: r.TranscriptFilePath,
		CreatedAt:          time.UnixMilli(r.CreatedAt),
		SummaryStatus:      domain.ProcessingStatus(r.SummaryStatus),
		Summary:            summary,
		SummaryGeneratedAt: summaryGeneratedAt,
		ServerRecordID:     r.ServerRecordID,
	}
}

func mapRows(rows []database.RecordRow) []domain.VoiceRecord {
	result := make([]domain.VoiceRecord, len(rows))
	for i, r := range rows {
		result[i] = rowToDomain(r)
	}
	return result
}
