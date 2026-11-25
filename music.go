package main

import (
	"math"
	"regexp"
	"sync"
	"time"
	"unicode/utf8"
)

var trackIDPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func validateMusic(value any) (Object, error) {
	input, ok := value.(map[string]any)
	if !ok {
		return nil, fail(400, "invalid_request")
	}
	state, _ := input["state"].(string)
	if state != "idle" && state != "ready" && state != "unavailable" && state != "offline" {
		return nil, fail(400, "invalid_request")
	}
	layout := "standard"
	if raw, exists := input["layout"]; exists {
		layout, ok = raw.(string)
		if !ok {
			return nil, fail(400, "invalid_request")
		}
	}
	if layout != "standard" && layout != "priority" && layout != "full" {
		return nil, fail(400, "invalid_request")
	}
	result := Object{"state": state, "layout": layout, "translationEnabled": false, "phoneticEnabled": false}
	for _, key := range []string{"enabled", "translationEnabled", "phoneticEnabled"} {
		if raw, exists := input[key]; exists {
			if _, ok := raw.(bool); !ok {
				return nil, fail(400, "invalid_request")
			}
			result[key] = raw
		}
	}
	if state != "ready" {
		return result, nil
	}
	for _, key := range []string{"title", "artist", "source", "lyricsState"} {
		text, ok := input[key].(string)
		if !ok || utf8.RuneCountInString(text) > 300 {
			return nil, fail(400, "invalid_request")
		}
		result[key] = text
	}
	lyrics := result["lyricsState"].(string)
	if lyrics != "ready" && lyrics != "loading" && lyrics != "missing" && lyrics != "error" {
		return nil, fail(400, "invalid_request")
	}
	playing, ok := input["playing"].(bool)
	if !ok {
		return nil, fail(400, "invalid_request")
	}
	result["playing"] = playing
	trackID := ""
	if raw, exists := input["trackId"]; exists {
		trackID, ok = raw.(string)
		if !ok {
			return nil, fail(400, "invalid_request")
		}
	}
	if trackID != "" && !trackIDPattern.MatchString(trackID) {
		return nil, fail(400, "invalid_request")
	}
	result["trackId"] = trackID
	for _, key := range []string{"position", "duration"} {
		n, ok := number(input[key])
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || n > 86400 {
			return nil, fail(400, "invalid_request")
		}
		result[key] = n
	}
	lines, ok := input["lines"].([]any)
	if !ok || len(lines) > 1000 {
		return nil, fail(400, "invalid_request")
	}
	clean := make([]any, 0, len(lines))
	previous := -1.0
	for _, raw := range lines {
		line, ok := raw.(map[string]any)
		if !ok {
			return nil, fail(400, "invalid_request")
		}
		stamp, numeric := number(line["time"])
		text, textual := line["text"].(string)
		if !numeric || math.IsNaN(stamp) || math.IsInf(stamp, 0) || stamp < 0 || stamp < previous || stamp > 86400 || !textual || utf8.RuneCountInString(text) > 300 {
			return nil, fail(400, "invalid_request")
		}
		cleanLine := Object{"time": stamp, "text": text}
		// 翻译与注音是可选文本；仍按白名单校验，不能借歌词透传其他本机数据。
		for _, key := range []string{"translation", "phonetic"} {
			if raw, exists := line[key]; exists {
				text, ok := raw.(string)
				if !ok || utf8.RuneCountInString(text) > 300 {
					return nil, fail(400, "invalid_request")
				}
				cleanLine[key] = text
			}
		}
		clean = append(clean, cleanLine)
		previous = stamp
	}
	result["lines"] = clean
	return result, nil
}

type musicCommand struct {
	payload Object
	expires time.Time
	result  *bool
	done    chan struct{}
}

type Music struct {
	mu       sync.Mutex
	snapshot Object
	received time.Time
	command  *musicCommand
	changed  chan struct{}
}

func NewMusic() *Music { return &Music{changed: make(chan struct{})} }

func (m *Music) notifyLocked() {
	close(m.changed)
	m.changed = make(chan struct{})
}

func (m *Music) Put(value Object) error {
	clean, err := validateMusic(value)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.snapshot, m.received = clean, time.Now()
	return nil
}

func (m *Music) Get() Object {
	m.mu.Lock()
	defer m.mu.Unlock()
	age := time.Since(m.received).Seconds()
	if m.snapshot == nil || age > 8 {
		result := Object{"state": "offline", "layout": "standard", "translationEnabled": false, "phoneticEnabled": false}
		// 断线只保留布局和开关，不继续展示或推演旧歌曲。
		if m.snapshot != nil {
			result["layout"] = m.snapshot["layout"]
			for _, key := range []string{"enabled", "translationEnabled", "phoneticEnabled"} {
				if value, exists := m.snapshot[key]; exists {
					result[key] = value
				}
			}
		}
		return result
	}
	result := clone(m.snapshot)
	if result["state"] == "ready" && result["playing"] == true {
		result["position"] = math.Min(result["duration"].(float64), result["position"].(float64)+age)
	}
	return result
}

func (m *Music) Control(value Object) (Object, error) {
	action, _ := value["action"].(string)
	track, _ := value["trackId"].(string)
	if (action != "previous" && action != "replay" && action != "play" && action != "pause" && action != "next") || !trackIDPattern.MatchString(track) {
		return nil, fail(400, "invalid_request")
	}
	m.mu.Lock()
	if m.snapshot == nil || m.snapshot["state"] != "ready" || time.Since(m.received) > 8*time.Second || m.snapshot["trackId"] != track || m.command != nil {
		m.mu.Unlock()
		return Object{"ok": false, "error": "unavailable"}, nil
	}
	command := &musicCommand{payload: Object{"requestId": newID(), "action": action, "trackId": track}, expires: time.Now().Add(8 * time.Second), done: make(chan struct{})}
	m.command = command
	m.notifyLocked()
	m.mu.Unlock()
	timer := time.NewTimer(time.Until(command.expires))
	defer timer.Stop()
	select {
	case <-command.done:
	case <-timer.C:
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	// 超时即撤销，Mac 恢复连接后不能补执行过期点按。
	if m.command == command {
		m.command = nil
	}
	if command.result != nil && *command.result {
		return Object{"ok": true, "error": nil}, nil
	}
	return Object{"ok": false, "error": "unconfirmed"}, nil
}

func (m *Music) PendingControl(wait time.Duration) Object {
	m.mu.Lock()
	if wait > 0 && m.command == nil {
		changed := m.changed
		m.mu.Unlock()
		timer := time.NewTimer(wait)
		select {
		case <-changed:
		case <-timer.C:
		}
		timer.Stop()
		m.mu.Lock()
	}
	defer m.mu.Unlock()
	if m.command == nil || m.command.result != nil || !time.Now().Before(m.command.expires) {
		return nil
	}
	result := clone(m.command.payload)
	result["expiresIn"] = time.Until(m.command.expires).Seconds()
	return result
}

func (m *Music) Acknowledge(value any) error {
	input, ok := value.(map[string]any)
	if !ok {
		return fail(400, "invalid_request")
	}
	id, idOK := input["requestId"].(string)
	accepted, acceptedOK := input["ok"].(bool)
	if !idOK || !acceptedOK {
		return fail(400, "invalid_request")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.command != nil && m.command.payload["requestId"] == id && m.command.result == nil && time.Now().Before(m.command.expires) {
		m.command.result = &accepted
		close(m.command.done)
	}
	return nil
}
