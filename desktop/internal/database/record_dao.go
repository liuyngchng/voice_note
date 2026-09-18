// Package database provides SQLite persistence for voice records.
package database

import (
	"context"
	"database/sql"
)

// RecordDAO implements data access for voice_records.
type RecordDAO struct {
	conn *sql.DB
}

// NewRecordDAO creates a new RecordDAO.
func NewRecordDAO(conn *sql.DB) *RecordDAO {
	return &RecordDAO{conn: conn}
}

// Insert creates a new record and returns its generated ID.
func (d *RecordDAO) Insert(ctx context.Context, r *RecordRow) (int64, error) {
	res, err := d.conn.ExecContext(ctx, `
		INSERT INTO voice_records
			(title, memo, description, speakers_json, source_type,
			 start_time, end_time, audio_file_path, transcript_file_path,
			 transcript_status, created_at, summary_json, summary_status,
			 summary_generated_at, server_record_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		r.Title, r.Memo, r.Description, r.SpeakersJSON, r.SourceType,
		r.StartTime, r.EndTime, r.AudioFilePath, r.TranscriptFilePath,
		r.TranscriptStatus, r.CreatedAt, r.SummaryJSON, r.SummaryStatus,
		r.SummaryGeneratedAt, r.ServerRecordID,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// Update overwrites all columns for an existing record (matched by id).
func (d *RecordDAO) Update(ctx context.Context, r *RecordRow) error {
	_, err := d.conn.ExecContext(ctx, `
		UPDATE voice_records SET
			title = ?, memo = ?, description = ?, speakers_json = ?,
			source_type = ?, start_time = ?, end_time = ?,
			audio_file_path = ?, transcript_file_path = ?,
			transcript_status = ?, created_at = ?,
			summary_json = ?, summary_status = ?,
			summary_generated_at = ?, server_record_id = ?
		WHERE id = ?
	`,
		r.Title, r.Memo, r.Description, r.SpeakersJSON,
		r.SourceType, r.StartTime, r.EndTime,
		r.AudioFilePath, r.TranscriptFilePath,
		r.TranscriptStatus, r.CreatedAt,
		r.SummaryJSON, r.SummaryStatus,
		r.SummaryGeneratedAt, r.ServerRecordID,
		r.ID,
	)
	return err
}

// GetByID returns a single record or nil.
func (d *RecordDAO) GetByID(ctx context.Context, id int64) (*RecordRow, error) {
	row := d.conn.QueryRowContext(ctx,
		`SELECT id, title, memo, description, speakers_json, source_type,
		        start_time, end_time, audio_file_path, transcript_file_path,
		        transcript_status, created_at, summary_json, summary_status,
		        summary_generated_at, server_record_id
		 FROM voice_records WHERE id = ?`, id)
	r := &RecordRow{}
	err := scanRow(row, r)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return r, nil
}

// GetAll returns all records ordered by start_time descending.
func (d *RecordDAO) GetAll(ctx context.Context) ([]RecordRow, error) {
	rows, err := d.conn.QueryContext(ctx, `
		SELECT id, title, memo, description, speakers_json, source_type,
		       start_time, end_time, audio_file_path, transcript_file_path,
		       transcript_status, created_at, summary_json, summary_status,
		       summary_generated_at, server_record_id
		FROM voice_records
		ORDER BY start_time DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanRows(rows)
}

// Search returns records matching query in title, memo, or description.
func (d *RecordDAO) Search(ctx context.Context, query string) ([]RecordRow, error) {
	pattern := "%" + query + "%"
	rows, err := d.conn.QueryContext(ctx, `
		SELECT id, title, memo, description, speakers_json, source_type,
		       start_time, end_time, audio_file_path, transcript_file_path,
		       transcript_status, created_at, summary_json, summary_status,
		       summary_generated_at, server_record_id
		FROM voice_records
		WHERE title LIKE ? OR memo LIKE ? OR description LIKE ?
		ORDER BY start_time DESC
	`, pattern, pattern, pattern)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanRows(rows)
}

// GetByDateRange returns records within the given epoch-millis range.
func (d *RecordDAO) GetByDateRange(ctx context.Context, from, to int64) ([]RecordRow, error) {
	rows, err := d.conn.QueryContext(ctx, `
		SELECT id, title, memo, description, speakers_json, source_type,
		       start_time, end_time, audio_file_path, transcript_file_path,
		       transcript_status, created_at, summary_json, summary_status,
		       summary_generated_at, server_record_id
		FROM voice_records
		WHERE start_time BETWEEN ? AND ?
		ORDER BY start_time DESC
	`, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanRows(rows)
}

// UpdateStartTime sets the start_time for a record.
func (d *RecordDAO) UpdateStartTime(ctx context.Context, id, startTime int64) error {
	_, err := d.conn.ExecContext(ctx,
		`UPDATE voice_records SET start_time = ? WHERE id = ?`, startTime, id)
	return err
}

// DeleteByID removes a record.
func (d *RecordDAO) DeleteByID(ctx context.Context, id int64) error {
	_, err := d.conn.ExecContext(ctx,
		`DELETE FROM voice_records WHERE id = ?`, id)
	return err
}

// GetAllTitles returns distinct titles.
func (d *RecordDAO) GetAllTitles(ctx context.Context) ([]string, error) {
	rows, err := d.conn.QueryContext(ctx,
		`SELECT DISTINCT title FROM voice_records ORDER BY title`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var titles []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		titles = append(titles, t)
	}
	return titles, rows.Err()
}

// UpdateSummary persists the summary JSON and status.
func (d *RecordDAO) UpdateSummary(ctx context.Context, id int64, summaryJSON, summaryStatus string, summaryGeneratedAt *int64) error {
	_, err := d.conn.ExecContext(ctx,
		`UPDATE voice_records SET summary_json = ?, summary_status = ?, summary_generated_at = ? WHERE id = ?`,
		summaryJSON, summaryStatus, summaryGeneratedAt, id)
	return err
}

// UpdateSummaryStatus changes only the summary status.
func (d *RecordDAO) UpdateSummaryStatus(ctx context.Context, id int64, summaryStatus string) error {
	_, err := d.conn.ExecContext(ctx,
		`UPDATE voice_records SET summary_status = ? WHERE id = ?`, summaryStatus, id)
	return err
}

// UpdateServerRecordID sets the server-assigned record ID.
func (d *RecordDAO) UpdateServerRecordID(ctx context.Context, id int64, serverRecordID string) error {
	_, err := d.conn.ExecContext(ctx,
		`UPDATE voice_records SET server_record_id = ? WHERE id = ?`, serverRecordID, id)
	return err
}

// RecordRow is the raw database row matching the voice_records table.
type RecordRow struct {
	ID                 int64
	Title              string
	Memo               string
	Description        string
	SpeakersJSON       string
	SourceType         string
	StartTime          int64
	EndTime            *int64
	AudioFilePath      string
	TranscriptFilePath string
	TranscriptStatus   string
	CreatedAt          int64
	SummaryJSON        string
	SummaryStatus      string
	SummaryGeneratedAt *int64
	ServerRecordID     string
}

func scanRow(scanner interface{ Scan(...interface{}) error }, r *RecordRow) error {
	return scanner.Scan(
		&r.ID, &r.Title, &r.Memo, &r.Description, &r.SpeakersJSON,
		&r.SourceType, &r.StartTime, &r.EndTime, &r.AudioFilePath,
		&r.TranscriptFilePath, &r.TranscriptStatus, &r.CreatedAt,
		&r.SummaryJSON, &r.SummaryStatus, &r.SummaryGeneratedAt,
		&r.ServerRecordID,
	)
}

func scanRows(rows *sql.Rows) ([]RecordRow, error) {
	var result []RecordRow
	for rows.Next() {
		var r RecordRow
		if err := scanRow(rows, &r); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, rows.Err()
}