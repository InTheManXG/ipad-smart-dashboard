package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type httpTestReply struct {
	status int
	value  any
	header http.Header
	body   []byte
	err    error
}

type httpFixture struct {
	t      *testing.T
	root   string
	data   string
	app    *server
	server *httptest.Server
}

func newHTTPFixture(t *testing.T, mode string) *httpFixture {
	t.Helper()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "web"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "web", "index.html"), []byte("任务现场"), 0644); err != nil {
		t.Fatal(err)
	}
	f := &httpFixture{t: t, root: root, data: filepath.Join(root, "data")}
	f.start(mode)
	t.Cleanup(f.close)
	return f
}

func (f *httpFixture) start(mode string) {
	f.t.Helper()
	var err error
	f.app, err = newServer(f.root, f.data, mode)
	if err != nil {
		f.t.Fatal(err)
	}
	f.server = httptest.NewServer(f.app)
	f.server.Client().Timeout = 10 * time.Second
}

func (f *httpFixture) close() {
	if f.server != nil {
		f.server.Close()
		f.server = nil
	}
	if f.app != nil && f.app.store != nil {
		if err := f.app.store.Close(); err != nil {
			f.t.Error(err)
		}
		f.app = nil
	}
}

func sendHTTP(client *http.Client, method, address string, body []byte, headers map[string]string) httpTestReply {
	request, err := http.NewRequest(method, address, bytes.NewReader(body))
	if err != nil {
		return httpTestReply{err: err}
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response, err := client.Do(request)
	if err != nil {
		return httpTestReply{err: err}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(response.Body)
	reply := httpTestReply{status: response.StatusCode, header: response.Header, body: raw, err: err}
	_ = json.Unmarshal(raw, &reply.value)
	return reply
}

func jsonHTTPBody(value any) []byte {
	if value == nil {
		return nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return data
}

func (f *httpFixture) call(method, path string, value any, headers map[string]string, status int) httpTestReply {
	f.t.Helper()
	reply := sendHTTP(f.server.Client(), method, f.server.URL+path, jsonHTTPBody(value), headers)
	if reply.err != nil {
		f.t.Fatal(reply.err)
	}
	if reply.status != status {
		f.t.Fatalf("%s %s: got %d %s, want %d", method, path, reply.status, reply.body, status)
	}
	return reply
}

func httpObject(t *testing.T, reply httpTestReply) Object {
	t.Helper()
	value, ok := reply.value.(map[string]any)
	if !ok {
		t.Fatalf("want JSON object, got %s", reply.body)
	}
	return value
}

func (f *httpFixture) pair(deviceHeaders map[string]string, ua string) (map[string]string, string) {
	f.t.Helper()
	code := httpObject(f.t, f.call("POST", "/api/pairing/code", Object{}, deviceHeaders, 200))["code"]
	reply := httpObject(f.t, f.call("POST", "/api/pairing/complete", Object{"code": code}, map[string]string{"User-Agent": ua}, 200))
	web := map[string]string{"X-Pairing-Token": reply["token"].(string)}
	screen := httpObject(f.t, f.call("GET", "/api/permissions", nil, web, 200))["screenId"].(string)
	// 配对码只能消费一次，不能用重放请求增加屏幕。
	f.call("POST", "/api/pairing/complete", Object{"code": code}, nil, 401)
	return web, screen
}

func (f *httpFixture) register() map[string]string {
	f.t.Helper()
	token := randomToken()
	f.call("POST", "/api/pairing/register", Object{"deviceId": newID(), "deviceToken": token, "name": "测试 Mac"}, nil, 200)
	return map[string]string{"X-Device-Token": token}
}

func (f *httpFixture) async(method, path string, value any, headers map[string]string) <-chan httpTestReply {
	done := make(chan httpTestReply, 1)
	go func() {
		done <- sendHTTP(f.server.Client(), method, f.server.URL+path, jsonHTTPBody(value), headers)
	}()
	return done
}

func awaitHTTPReply(t *testing.T, done <-chan httpTestReply, status int) httpTestReply {
	t.Helper()
	select {
	case reply := <-done:
		if reply.err != nil || reply.status != status {
			t.Fatalf("asynchronous reply: got %d %s (%v), want %d", reply.status, reply.body, reply.err, status)
		}
		return reply
	case <-time.After(3 * time.Second):
		t.Fatal("waiting HTTP request was not woken")
		return httpTestReply{}
	}
}

func (f *httpFixture) awaitCommand(device map[string]string, snapshot Object) Object {
	f.t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		value := httpObject(f.t, f.call("POST", "/api/device/exchange", Object{"status": snapshot}, device, 200))
		commands, ok := value["commands"].([]any)
		if !ok {
			f.t.Fatalf("commands must be an array, got %#v", value["commands"])
		}
		if len(commands) != 0 {
			if len(commands) != 1 {
				f.t.Fatalf("want one command, got %d", len(commands))
			}
			return commands[0].(map[string]any)
		}
		time.Sleep(10 * time.Millisecond)
	}
	f.t.Fatal("command was not delivered")
	return nil
}

func TestHTTPPairingPermissionsAndCommands(t *testing.T) {
	f := newHTTPFixture(t, "pairing")
	device, other := f.register(), f.register()
	web, screen := f.pair(device, "iPad test")
	permission := httpObject(t, f.call("GET", "/api/permissions", nil, web, 200))
	if permission["controlAllowed"] != false {
		t.Fatal("new screen must be read-only")
	}
	f.call("GET", "/api/permissions", nil, nil, 401)
	change := Object{"id": screen, "controlAllowed": true}
	f.call("POST", "/api/pairing/permission", change, web, 401)
	f.call("POST", "/api/pairing/permission", change, other, 404)
	f.call("POST", "/api/pairing/permission", Object{"id": screen, "controlAllowed": "true"}, device, 400)
	for path, body := range map[string]Object{
		"/api/open":          {"threadId": newID()},
		"/api/music/control": {"action": "play"},
		"/api/console/run":   {"id": newID()},
	} {
		f.call("POST", path, body, web, 403)
	}
	target, action, key := newID(), newID(), newID()
	snapshot := Object{"conversations": []any{Object{"threadId": target, "title": "测试任务", "private": "PRIVATE-SENTINEL"}}, "deviceToken": "PRIVATE-SENTINEL"}
	f.call("POST", "/api/device/exchange", Object{
		"status":  snapshot,
		"music":   Object{"state": "idle", "enabled": false},
		"keys":    []any{Object{"id": key, "name": "测试 Key", "key": "PRIVATE-SENTINEL", "usage": Object{"remaining": 12}}},
		"console": []any{Object{"id": action, "name": "测试脚本", "kind": "script", "state": "idle", "target": "PRIVATE-SENTINEL"}},
	}, device, 200)
	for _, path := range []string{"/api/status", "/api/music", "/api/relay/keys", "/api/console"} {
		reply := f.call("GET", path, nil, web, 200)
		if bytes.Contains(reply.body, []byte("PRIVATE-SENTINEL")) {
			t.Fatalf("%s exposed a private snapshot field", path)
		}
	}
	otherWeb, _ := f.pair(other, "other device")
	f.call("GET", "/api/status", nil, otherWeb, 503)
	f.call("POST", "/api/pairing/permission", change, device, 200)
	f.call("POST", "/api/open", Object{"threadId": newID()}, web, 409)
	f.call("POST", "/api/console/run", Object{"id": action, "target": "injected"}, web, 400)
	done := f.async("POST", "/api/open", Object{"threadId": target}, web)
	command := f.awaitCommand(device, snapshot)
	if command["kind"] != "open" || command["threadId"] != target || command["screenId"] != screen {
		t.Fatalf("wrong command payload: %#v", command)
	}
	next := httpObject(t, f.call("POST", "/api/device/exchange", Object{"status": snapshot}, device, 200))
	if len(next["commands"].([]any)) != 0 {
		t.Fatal("in-flight command was delivered more than once")
	}
	f.call("POST", "/api/device/exchange", Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true}}}, device, 200)
	if httpObject(t, awaitHTTPReply(t, done, 200))["ok"] != true {
		t.Fatal("successful acknowledgement was lost")
	}
	// 撤权会终止等待中的控制；之后到达的成功回执不能恢复权限。
	done = f.async("POST", "/api/open", Object{"threadId": target}, web)
	command = f.awaitCommand(device, snapshot)
	f.call("POST", "/api/pairing/permission", Object{"id": screen, "controlAllowed": false}, device, 200)
	f.call("POST", "/api/device/exchange", Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true}}}, device, 200)
	awaitHTTPReply(t, done, 403)
	f.call("GET", "/api/status", nil, web, 200)
	for _, path := range []string{"/api/subscriptions", "/api/music/ack"} {
		f.call("POST", path, Object{}, web, 404)
	}
}

func TestHTTPKickAndRevokeIsolateScreens(t *testing.T) {
	f := newHTTPFixture(t, "pairing")
	device, other := f.register(), f.register()
	first, screen := f.pair(device, "first")
	second, _ := f.pair(device, "second")
	key := newID()
	f.call("POST", "/api/device/exchange", Object{"status": Object{}, "keys": []any{Object{"id": key, "name": "额度"}}}, device, 200)
	done := f.async("GET", "/api/relay/usage?id="+key+"&refresh=1", nil, first)
	command := f.awaitCommand(device, Object{})
	f.call("POST", "/api/pairing/kick", Object{"id": screen}, other, 404)
	f.call("POST", "/api/pairing/kick", Object{"id": screen}, device, 200)
	f.call("POST", "/api/device/exchange", Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true, "usage": Object{"remaining": 1}}}}, device, 200)
	awaitHTTPReply(t, done, 401)
	f.call("GET", "/api/permissions", nil, first, 401)
	f.call("GET", "/api/permissions", nil, second, 200)
	f.call("POST", "/api/pairing/revoke", Object{}, device, 200)
	f.call("GET", "/api/permissions", nil, second, 401)
	fresh, _ := f.pair(device, "new session")
	f.call("POST", "/api/pairing/leave", Object{}, fresh, 200)
	f.call("POST", "/api/pairing/leave", Object{}, fresh, 401)
}

func TestHTTPPairingSurvivesRestart(t *testing.T) {
	f := newHTTPFixture(t, "pairing")
	device := f.register()
	web, screen := f.pair(device, "saved screen")
	f.call("POST", "/api/pairing/permission", Object{"id": screen, "controlAllowed": true}, device, 200)
	f.close()
	f.start("pairing")
	state := httpObject(t, f.call("GET", "/api/pairing/device", nil, device, 200))
	if state["paired"] != true || state["screenCount"] != float64(1) {
		t.Fatalf("pairing was not preserved: %#v", state)
	}
	permission := httpObject(t, f.call("GET", "/api/permissions", nil, web, 200))
	if permission["screenId"] != screen || permission["controlAllowed"] != true {
		t.Fatalf("saved permission changed: %#v", permission)
	}
	f.call("GET", "/api/status", nil, web, 503)
	info, err := os.Stat(filepath.Join(f.data, "pairing.sqlite"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("database must stay private: %v %v", info, err)
	}
}

func TestHTTPOldSQLiteSessionDefaultsToReadOnly(t *testing.T) {
	f := newHTTPFixture(t, "pairing")
	f.close()
	path := filepath.Join(f.data, "pairing.sqlite")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	device, deviceToken, webToken, screen := newID(), randomToken(), randomToken(), newID()
	_, err = db.Exec(`
		CREATE TABLE devices (id TEXT PRIMARY KEY, secret TEXT UNIQUE NOT NULL, name TEXT NOT NULL, code TEXT UNIQUE, expires REAL NOT NULL DEFAULT 0, seen REAL NOT NULL);
		CREATE TABLE sessions (secret TEXT PRIMARY KEY, device TEXT NOT NULL, expires REAL NOT NULL);
		CREATE TABLE screens (secret TEXT PRIMARY KEY REFERENCES sessions(secret) ON DELETE CASCADE, id TEXT UNIQUE NOT NULL, remark TEXT NOT NULL DEFAULT '', ua TEXT NOT NULL DEFAULT '', seen REAL NOT NULL DEFAULT 0);
		INSERT INTO devices(id,secret,name,seen) VALUES(?,?,?,?);
		INSERT INTO sessions VALUES(?,?,?);
		INSERT INTO screens(secret,id) VALUES(?,?);`, device, digest(deviceToken), "旧版本 Mac", float64(time.Now().Unix()), digest(webToken), device, float64(time.Now().Add(time.Hour).Unix()), digest(webToken), screen)
	if err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	f.start("pairing")
	f.call("GET", "/api/pairing/device", nil, map[string]string{"X-Device-Token": deviceToken}, 200)
	value := httpObject(t, f.call("GET", "/api/permissions", nil, map[string]string{"X-Pairing-Token": webToken}, 200))
	if value["screenId"] != screen || value["controlAllowed"] != false {
		t.Fatalf("old screen must remain paired and read-only: %#v", value)
	}
}

func TestHTTPBodyAndStaticBoundaries(t *testing.T) {
	f := newHTTPFixture(t, "pairing")
	mode := httpObject(t, f.call("GET", "/api/mode", nil, nil, 200))
	if mode["mode"] != "pairing" {
		t.Fatalf("wrong mode: %#v", mode)
	}
	page := f.call("GET", "/", nil, nil, 200)
	if string(page.body) != "任务现场" || page.header.Get("Cache-Control") != "no-store" || page.header.Get("X-Content-Type-Options") != "nosniff" || !strings.Contains(page.header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("missing static content or security headers: %s %#v", page.body, page.header)
	}
	for _, path := range []string{"/.display-token", "/../../server.py", "/%2e%2e/server.go", "/subscriptions.js"} {
		f.call("GET", path, nil, nil, 404)
	}
	for _, body := range []string{"null", "[]", "1", "{}{}", `{"deviceId":NaN}`} {
		reply := sendHTTP(f.server.Client(), "POST", f.server.URL+"/api/pairing/register", []byte(body), nil)
		if reply.err != nil || reply.status != 400 {
			t.Errorf("invalid JSON %q: got %d (%v), want 400", body, reply.status, reply.err)
		}
	}
	for _, test := range []struct {
		path string
		size int
	}{
		{"/api/pairing/register", 1025},
		{"/api/device/exchange", 3200001},
	} {
		reply := sendHTTP(f.server.Client(), "POST", f.server.URL+test.path, bytes.Repeat([]byte(" "), test.size), nil)
		if reply.err != nil || reply.status != 413 {
			t.Errorf("oversized %s: got %d (%v), want 413", test.path, reply.status, reply.err)
		}
	}
	request, err := http.NewRequest("POST", f.server.URL+"/api/pairing/register", io.NopCloser(strings.NewReader("{}")))
	if err != nil {
		t.Fatal(err)
	}
	request.ContentLength = -1
	response, err := f.server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 400 {
		t.Fatalf("chunked request: got %d, want 400", response.StatusCode)
	}
}

func TestHTTPLegacyAuthenticationAndBridge(t *testing.T) {
	target := newID()
	var opened atomic.Int32
	bridge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Codex-Status-Token") != "test-status-token" {
			http.Error(w, "unauthorized", 401)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/open" {
			var body Object
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["threadId"] != target {
				http.Error(w, "invalid target", 400)
				return
			}
			opened.Add(1)
			_ = json.NewEncoder(w).Encode(Object{"ok": true})
			return
		}
		_ = json.NewEncoder(w).Encode(Object{"schema": 1, "state": "waiting", "conversations": []any{Object{"threadId": target}}, "secret": "PRIVATE-SENTINEL"})
	}))
	defer bridge.Close()
	t.Setenv("CODEX_STATUS_TOKEN", "test-status-token")
	t.Setenv("STATUS_URL", bridge.URL+"/status")
	f := newHTTPFixture(t, "legacy")
	header := map[string]string{"X-Display-Token": f.app.token}
	if f.app.token == "" {
		t.Fatal("legacy mode did not create a token")
	}
	for _, path := range []string{"/api/status", "/api/permissions", "/api/music", "/api/relay/keys"} {
		unauthorized := httpObject(t, f.call("GET", path, nil, nil, 401))
		if len(unauthorized) != 0 {
			t.Fatal("legacy authentication response changed")
		}
	}
	value := httpObject(t, f.call("GET", "/api/permissions", nil, header, 200))
	if value["controlAllowed"] != true {
		t.Fatal("legacy manager lost its explicit control permission")
	}
	status := f.call("GET", "/api/status", nil, header, 200)
	if bytes.Contains(status.body, []byte("PRIVATE-SENTINEL")) {
		t.Fatal("legacy bridge leaked non-whitelisted field")
	}
	f.call("POST", "/api/open", Object{"threadId": "file:///tmp"}, header, 400)
	stale := httpObject(t, f.call("POST", "/api/open", Object{"threadId": newID()}, header, 409))
	if stale["ok"] != false || len(stale) != 1 {
		t.Fatal("legacy stale-target response changed")
	}
	unavailable := httpObject(t, f.call("POST", "/api/music/control", Object{"action": "play", "trackId": strings.Repeat("a", 64)}, header, 409))
	if unavailable["ok"] != false || unavailable["error"] != "unavailable" {
		t.Fatal("legacy music error response changed")
	}
	f.call("POST", "/api/open", Object{"threadId": target}, header, 200)
	if opened.Load() != 1 {
		t.Fatalf("only the known target may be opened, got %d opens", opened.Load())
	}
	for _, path := range []string{"/api/subscriptions", "/subscriptions.js"} {
		f.call("GET", path, nil, header, 404)
	}
}
