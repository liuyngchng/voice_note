// Package client implements a FunASR WebSocket 2pass client.
//
// It speaks the same protocol as FunASR's own funasr_wss_client.py:
//   - connect to ws://host:port/ with subprotocol "binary"
//   - send one JSON control message (mode=2pass, chunk_size=[5,10,5], ...)
//   - stream 16kHz/16-bit/mono PCM as binary frames
//   - receive JSON result frames ("2pass-online" partial / "2pass-offline" final)
package client

import (
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"github.com/gorilla/websocket"
)

// Result is a single recognition result frame pushed by the FunASR server.
type Result struct {
	Mode      string `json:"mode"`       // "2pass-online" (partial) or "2pass-offline" (finalized)
	Text      string `json:"text"`       // recognized text for this frame
	IsFinal   bool   `json:"is_final"`   // true when the server has finished the stream
	Timestamp string `json:"timestamp"`  // word-level timestamps (optional)
	WavName   string `json:"wav_name"`   // echo of the wav_name we sent
}

// config is the JSON control message sent right after connecting.
type config struct {
	Mode                 string `json:"mode"`
	ChunkSize            []int  `json:"chunk_size"`
	ChunkInterval        int    `json:"chunk_interval"`
	EncoderChunkLookBack int    `json:"encoder_chunk_look_back"`
	DecoderChunkLookBack int    `json:"decoder_chunk_look_back"`
	WavName              string `json:"wav_name"`
	IsSpeaking           bool   `json:"is_speaking"`
	Hotwords             string `json:"hotwords"`
	Itn                  bool   `json:"itn"`
}

// Client wraps a single FunASR WebSocket connection.
type Client struct {
	conn *websocket.Conn
}

// Connect dials the FunASR server and sends the 2pass control message.
func (c *Client) Connect(host string, port int) error {
	u := url.URL{Scheme: "ws", Host: fmt.Sprintf("%s:%d", host, port), Path: "/"}

	dialer := websocket.Dialer{
		Subprotocols:    []string{"binary"},
		HandshakeTimeout: 10 * time.Second,
	}
	conn, _, err := dialer.Dial(u.String(), nil)
	if err != nil {
		return fmt.Errorf("connect %s: %w", u.String(), err)
	}
	c.conn = conn

	cfg := config{
		Mode:                 "2pass",
		ChunkSize:            []int{5, 10, 5},
		ChunkInterval:        10,
		EncoderChunkLookBack: 4,
		DecoderChunkLookBack: 0,
		WavName:              "microphone",
		IsSpeaking:           true,
		Hotwords:             "",
		Itn:                  true,
	}
	payload, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
		return fmt.Errorf("send config: %w", err)
	}
	return nil
}

// SendAudio streams one chunk of 16-bit little-endian mono PCM.
func (c *Client) SendAudio(pcm []byte) error {
	if c.conn == nil {
		return fmt.Errorf("client: not connected")
	}
	return c.conn.WriteMessage(websocket.BinaryMessage, pcm)
}

// SendEnd signals the server that no more audio is coming.
func (c *Client) SendEnd() error {
	if c.conn == nil {
		return nil
	}
	payload, _ := json.Marshal(map[string]bool{"is_speaking": false})
	return c.conn.WriteMessage(websocket.TextMessage, payload)
}

// SendPause tells the server to finalize the current utterance and pause recognition.
func (c *Client) SendPause() error {
	return c.SendEnd() // same wire message: {"is_speaking": false}
}

// SendResume tells the server to resume recognition after a pause.
func (c *Client) SendResume() error {
	if c.conn == nil {
		return fmt.Errorf("client: not connected")
	}
	payload, _ := json.Marshal(map[string]bool{"is_speaking": true})
	return c.conn.WriteMessage(websocket.TextMessage, payload)
}

// ReadNext blocks until the next result frame arrives.
func (c *Client) ReadNext() (*Result, error) {
	if c.conn == nil {
		return nil, fmt.Errorf("client: not connected")
	}
	_, msg, err := c.conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	var r Result
	if err := json.Unmarshal(msg, &r); err != nil {
		return nil, fmt.Errorf("decode result: %w", err)
	}
	return &r, nil
}

// Close closes the underlying connection.
func (c *Client) Close() {
	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
	}
}
