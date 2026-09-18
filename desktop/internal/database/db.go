// Package database provides SQLite persistence for voice records.
package database

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	_ "modernc.org/sqlite"
)

// DB wraps the SQLite connection and provides RecordDAO access.
type DB struct {
	conn      *sql.DB
	RecordDAO *RecordDAO
}

var (
	instance *DB
	once     sync.Once
)

// Open returns the singleton database instance. The data file is stored
// at dataDir/voice_note.db. Use an empty string to default to the platform
// user-data directory.
func Open(dataDir string) (*DB, error) {
	var initErr error
	once.Do(func() {
		if dataDir == "" {
			dataDir = defaultDataDir()
		}
		if err := os.MkdirAll(dataDir, 0700); err != nil {
			initErr = fmt.Errorf("database: create data dir: %w", err)
			return
		}
		dbPath := filepath.Join(dataDir, "voice_note.db")
		conn, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
		if err != nil {
			initErr = fmt.Errorf("database: open: %w", err)
			return
		}
		// SQLite pragma for performance and safety.
		if _, err := conn.Exec("PRAGMA foreign_keys = ON"); err != nil {
			conn.Close()
			initErr = fmt.Errorf("database: pragma: %w", err)
			return
		}
		instance = &DB{conn: conn}
		if err := instance.migrate(context.Background()); err != nil {
			conn.Close()
			initErr = err
			return
		}
		instance.RecordDAO = NewRecordDAO(conn)
	})
	return instance, initErr
}

// Close shuts down the database connection.
func (db *DB) Close() error {
	return db.conn.Close()
}

// migrate creates or upgrades the schema. Version numbering mirrors the
// Android Room database versions (initial schema = v1, summary columns = v7,
// serverRecordId = v8).
func (db *DB) migrate(ctx context.Context) error {
	// Enable WAL for concurrent reads during writes (recording + UI queries).
	if _, err := db.conn.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		return fmt.Errorf("database: enable WAL: %w", err)
	}

	_, err := db.conn.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS voice_records (
			id                  INTEGER PRIMARY KEY AUTOINCREMENT,
			title               TEXT NOT NULL,
			memo                TEXT NOT NULL DEFAULT '',
			description         TEXT NOT NULL DEFAULT '',
			speakers_json       TEXT NOT NULL DEFAULT '[]',
			source_type         TEXT NOT NULL DEFAULT 'RECORDING',
			start_time          INTEGER NOT NULL,
			end_time            INTEGER,
			audio_file_path     TEXT NOT NULL DEFAULT '',
			transcript_file_path TEXT NOT NULL DEFAULT '',
			transcript_status   TEXT NOT NULL DEFAULT 'PENDING',
			created_at          INTEGER NOT NULL,
			summary_json        TEXT NOT NULL DEFAULT '',
			summary_status      TEXT NOT NULL DEFAULT 'PENDING',
			summary_generated_at INTEGER,
			server_record_id    TEXT NOT NULL DEFAULT ''
		)
	`)
	if err != nil {
		return fmt.Errorf("database: create table: %w", err)
	}

	// All columns included in the initial CREATE TABLE so no on-disk
	// migrations needed for first-time installs.
	return nil
}
