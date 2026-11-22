package main

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func relayTestStation(t *testing.T, relay *Relay, address string) {
	t.Helper()
	data, _ := json.Marshal(Object{"type": "sub2api", "url": address})
	if err := os.WriteFile(filepath.Join(relay.dataDir, "station.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func relayTestKey(t *testing.T, relay *Relay, key string) string {
	t.Helper()
	if _, err := relay.ChangeKey(Object{"action": "save", "name": "测试", "key": key}); err != nil {
		t.Fatal(err)
	}
	items, err := relay.PublicKeys()
	if err != nil {
		t.Fatal(err)
	}
	return items.([]Object)[len(items.([]Object))-1]["id"].(string)
}

func TestRelayKeysPersistenceAndMasking(t *testing.T) {
	r := NewRelay(t.TempDir())
	id := relayTestKey(t, r, "test-secret")
	relayTestKey(t, r, "abcdef")
	items, err := r.PublicKeys()
	if err != nil {
		t.Fatal(err)
	}
	keys := items.([]Object)
	if keys[0]["maskedKey"] != "te****cret" || keys[1]["maskedKey"] != "****" {
		t.Fatalf("incorrect masking: %v", keys)
	}
	encoded, _ := json.Marshal(items)
	if strings.Contains(string(encoded), "secret") || strings.Contains(string(encoded), `"key"`) {
		t.Fatal("public response leaked credentials")
	}
	if _, err := r.ChangeKey(Object{"action": "save", "id": id, "name": "改名", "key": ""}); err != nil {
		t.Fatal(err)
	}
	reopened := NewRelay(r.dataDir)
	stored, err := reopened.readKeysLocked()
	if err != nil || stored[0]["key"] != "test-secret" || stored[0]["name"] != "改名" {
		t.Fatalf("key did not survive rename/reopen: %v, %v", stored, err)
	}
	info, err := os.Stat(filepath.Join(r.dataDir, "keys.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("key file must be owner-only: %v", err)
	}
	for _, value := range []Object{
		{"action": "save", "name": "", "key": "x"}, {"action": "save", "name": "x", "key": "a\nb"},
		{"action": "save", "name": "x", "key": "非ASCII"}, {"action": "delete", "id": "missing"},
		{"action": "save", "id": []any{}, "name": "x", "key": "x"},
	} {
		if _, err := r.ChangeKey(value); err == nil {
			t.Errorf("invalid key mutation accepted: %v", value)
		}
	}
	if _, err := r.ChangeKey(Object{"action": "delete", "id": id}); err != nil {
		t.Fatal(err)
	}
	items, err = r.PublicKeys()
	if err != nil || len(items.([]Object)) != 1 {
		t.Fatal("delete failed or rejected updates mutated storage")
	}
}

func TestRelayStationValidation(t *testing.T) {
	r := NewRelay(t.TempDir())
	id := relayTestKey(t, r, "test-secret")
	if _, err := r.ReadUsage(id, false); err == nil {
		t.Fatal("missing station was accepted")
	}
	for _, address := range []string{"http://localhost", "http://relay.example.test", "https://user:pass@relay.example.test", "https://relay.example.test/other",
		"https://relay.example.test?token=secret", "https://relay.example.test#fragment", "https://relay.example.test:70000", "https://relay.example.test:0",
		"https://relay.example.test/a/../v1", "https://relay.example.test\\@other.test", "https://relay.example.test/%76%31", ""} {
		relayTestStation(t, r, address)
		if _, err := r.ReadUsage(id, false); err == nil {
			t.Errorf("invalid station accepted: %s", address)
		}
	}
	for _, address := range []string{"https://relay.example.test", "https://relay.example.test/", "https://relay.example.test/v1", "https://relay.example.test/v1/"} {
		relayTestStation(t, r, address)
		got, err := r.usageURLLocked()
		if err != nil || got != "https://relay.example.test/v1/usage" {
			t.Errorf("valid station rejected: %q, %v", got, err)
		}
	}
	for _, value := range []any{math.NaN(), math.Inf(1), true, float64(1e15)} {
		if usageNumber(value) != nil {
			t.Errorf("invalid upstream number accepted: %v", value)
		}
	}
}

func TestRelayUsageCacheWhitelistAndRefresh(t *testing.T) {
	r := NewRelay(t.TempDir())
	id := relayTestKey(t, r, "test-secret")
	var requests atomic.Int32
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		if req.URL.Path != "/v1/usage" || req.Header.Get("Authorization") != "Bearer test-secret" {
			t.Error("incorrect usage path or authorization")
		}
		io.WriteString(w, `{"isValid":true,"remaining":176.24,"unit":"USD","key":"must-not-leak","subscription":{"daily_limit_usd":300,"daily_usage_usd":123.76},"usage":{"today":{"cost":0}}}`)
	}))
	defer upstream.Close()
	r.client.Transport = upstream.Client().Transport
	relayTestStation(t, r, upstream.URL)
	for i := 0; i < 2; i++ {
		result, err := r.ReadUsage(id, false)
		if err != nil || result["remaining"] != 176.24 || result["dailyUsed"] != 123.76 {
			t.Fatalf("incorrect usage: %v, %v", result, err)
		}
		encoded, _ := json.Marshal(result)
		if strings.Contains(string(encoded), "must-not-leak") || len(result) != 5 {
			t.Fatal("upstream fields leaked")
		}
	}
	if requests.Load() != 1 {
		t.Fatal("cache missed")
	}
	if _, err := r.ReadUsage(id, true); err != nil || requests.Load() != 2 {
		t.Fatalf("explicit refresh failed: %v", err)
	}
	if _, err := r.ChangeKey(Object{"action": "save", "id": id, "name": "测试", "key": "replacement"}); err != nil {
		t.Fatal(err)
	}
	r.client.Transport = relayTestTransport(func(req *http.Request) (*http.Response, error) {
		if req.Header.Get("Authorization") != "Bearer replacement" {
			t.Error("cache retained old key")
		}
		return &http.Response{StatusCode: 401, Body: io.NopCloser(strings.NewReader("secret error detail")), Header: http.Header{}}, nil
	})
	result, err := r.ReadUsage(id, false)
	if err != nil || result["error"] != "Key 无效或无权访问" || len(result) != 2 {
		t.Fatalf("unsafe error response: %v, %v", result, err)
	}
}

type relayTestTransport func(*http.Request) (*http.Response, error)

func (f relayTestTransport) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestRelayRejectsRedirectOversizeAndChangedStation(t *testing.T) {
	r := NewRelay(t.TempDir())
	id := relayTestKey(t, r, "test-secret")
	relayTestStation(t, r, "https://first.example.test")
	var requests int
	r.client.Transport = relayTestTransport(func(req *http.Request) (*http.Response, error) {
		requests++
		return &http.Response{StatusCode: 302, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{"Location": {"https://second.example.test/v1/usage"}}, Request: req}, nil
	})
	result, err := r.ReadUsage(id, true)
	if err != nil || result["error"] != "中转站暂时不可用" || requests != 1 {
		t.Fatalf("redirect was followed or accepted: %v, %v, requests=%d", result, err, requests)
	}
	r.client.Transport = relayTestTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", 1_000_001))), Header: http.Header{}}, nil
	})
	result, err = r.ReadUsage(id, true)
	if err != nil || result["error"] != "查询失败，请检查 Key 或稍后重试" {
		t.Fatalf("oversize response accepted: %v, %v", result, err)
	}
	r.client.Transport = relayTestTransport(func(*http.Request) (*http.Response, error) {
		relayTestStation(t, r, "https://changed.example.test")
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"isValid":true,"remaining":1}`)), Header: http.Header{}}, nil
	})
	if _, err := r.ReadUsage(id, true); err == nil {
		t.Fatal("in-flight response reused after station change")
	}
	if r.cache[id].url != "https://first.example.test/v1/usage" {
		t.Fatal("stale response replaced cache after station change")
	}
}
