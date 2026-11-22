package main

import (
	"math"
	"strings"
	"testing"
	"time"
)

func musicTestSnapshot() Object {
	return Object{"state": "ready", "trackId": strings.Repeat("a", 64), "title": "测试歌曲", "artist": "歌手", "source": "播放器",
		"playing": true, "position": float64(10), "duration": float64(120), "lyricsState": "ready",
		"lines": []any{Object{"time": float64(0), "text": "第一句"}, Object{"time": float64(20), "text": "第二句"}}}
}

func TestMusicValidation(t *testing.T) {
	invalid := []Object{
		{"position": math.NaN()}, {"duration": math.Inf(1)}, {"playing": 1}, {"enabled": "true"}, {"title": strings.Repeat("中", 301)},
		{"lines": []any{Object{"time": float64(-1), "text": "bad"}}},
		{"lines": []any{Object{"time": float64(2), "text": "a"}, Object{"time": float64(1), "text": "b"}}},
		{"trackId": strings.Repeat("A", 64)}, {"lyricsState": "unknown"}, {"lines": nil},
	}
	for _, change := range invalid {
		value := musicTestSnapshot()
		for key, item := range change {
			value[key] = item
		}
		if _, err := validateMusic(value); err == nil {
			t.Errorf("invalid snapshot accepted: %v", change)
		}
	}
	for _, state := range []string{"ready", "idle", "unavailable", "offline"} {
		for _, layout := range []string{"standard", "priority", "full"} {
			value := musicTestSnapshot()
			value["state"], value["layout"], value["private"] = state, layout, "must-not-leak"
			clean, err := validateMusic(value)
			if err != nil || clean["layout"] != layout {
				t.Fatalf("valid state/layout rejected: %v, %v", clean, err)
			}
			if _, exists := clean["private"]; exists {
				t.Fatal("unlisted field leaked")
			}
			if state != "ready" {
				if _, exists := clean["lines"]; exists {
					t.Fatal("idle snapshot retained old lyrics")
				}
			}
		}
		for _, layout := range []any{nil, true, 1, []any{}, Object{}, "", "unknown", " full"} {
			value := musicTestSnapshot()
			value["state"], value["layout"] = state, layout
			if _, err := validateMusic(value); err == nil {
				t.Errorf("invalid layout accepted in %s", state)
			}
		}
	}
	value := musicTestSnapshot()
	value["title"] = strings.Repeat("中", 300)
	clean, err := validateMusic(value)
	if err != nil || clean["layout"] != "standard" {
		t.Fatalf("legacy snapshot or Unicode boundary rejected: %v", err)
	}
}

func TestMusicProgressAndOfflineLayout(t *testing.T) {
	m := NewMusic()
	value := musicTestSnapshot()
	value["enabled"], value["layout"] = false, "full"
	if err := m.Put(value); err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	m.received = time.Now().Add(-2 * time.Second)
	m.mu.Unlock()
	position := m.Get()["position"].(float64)
	if position < 12 || position > 12.5 {
		t.Fatalf("incorrect playing position: %v", position)
	}
	m.mu.Lock()
	m.received = time.Now().Add(-9 * time.Second)
	m.mu.Unlock()
	offline := m.Get()
	if len(offline) != 3 || offline["state"] != "offline" || offline["enabled"] != false || offline["layout"] != "full" {
		t.Fatalf("offline retained song data or lost display settings: %v", offline)
	}
	value["playing"] = false
	if err := m.Put(value); err != nil {
		t.Fatal(err)
	}
	if m.Get()["position"] != float64(10) {
		t.Fatal("paused progress changed")
	}
}

func TestMusicCommandDeliveryAndAcknowledgement(t *testing.T) {
	m := NewMusic()
	if err := m.Put(musicTestSnapshot()); err != nil {
		t.Fatal(err)
	}
	results := make(chan Object, 1)
	errors := make(chan error, 1)
	go func() {
		result, err := m.Control(Object{"action": "pause", "trackId": strings.Repeat("a", 64)})
		results <- result
		errors <- err
	}()
	command := m.PendingControl(time.Second)
	if command == nil || command["action"] != "pause" {
		t.Fatal("upload did not wake for command")
	}
	busy, err := m.Control(Object{"action": "pause", "trackId": strings.Repeat("a", 64)})
	if err != nil || busy["error"] != "unavailable" {
		t.Fatalf("concurrent command was accepted: %v, %v", busy, err)
	}
	if err := m.Acknowledge(Object{"requestId": "wrong-id", "ok": true}); err != nil {
		t.Fatal(err)
	}
	if m.PendingControl(0) == nil {
		t.Fatal("unrelated acknowledgement removed command")
	}
	updated := musicTestSnapshot()
	updated["playing"], updated["position"] = false, float64(13)
	if err := m.Put(updated); err != nil {
		t.Fatal(err)
	}
	if err := m.Acknowledge(Object{"requestId": command["requestId"], "ok": true}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-results:
		if result["ok"] != true || result["error"] != nil || <-errors != nil {
			t.Fatalf("acknowledgement failed: %v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("acknowledgement did not wake controller")
	}
	if m.PendingControl(0) != nil || m.Get()["position"] != float64(13) || m.Get()["playing"] != false {
		t.Fatal("confirmed state or pending command is incorrect")
	}
	if result, err := m.Control(Object{"action": "next", "trackId": strings.Repeat("b", 64)}); err != nil || result["ok"] != false {
		t.Fatal("changed track accepted old control")
	}
	if _, err := m.Control(Object{"action": "run", "trackId": strings.Repeat("a", 64)}); err == nil {
		t.Fatal("invalid action accepted")
	}
	if err := m.Acknowledge(Object{"requestId": command["requestId"], "ok": 1}); err == nil {
		t.Fatal("non-boolean acknowledgement accepted")
	}
}

func TestMusicExpiredCommandCannotBeDeliveredOrAcknowledged(t *testing.T) {
	m := NewMusic()
	command := &musicCommand{payload: Object{"requestId": "expired", "action": "next"}, expires: time.Now().Add(-time.Second), done: make(chan struct{})}
	m.command = command
	if m.PendingControl(0) != nil {
		t.Fatal("expired command was delivered")
	}
	if err := m.Acknowledge(Object{"requestId": "expired", "ok": true}); err != nil {
		t.Fatal(err)
	}
	if command.result != nil {
		t.Fatal("late acknowledgement accepted")
	}
}
