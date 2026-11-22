package main

import (
	"database/sql"
	"encoding/base64"
	"errors"
	"math"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func newPairingStore(t *testing.T) *Store {
	t.Helper()
	store, err := NewStore(filepath.Join(t.TempDir(), "pairing.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func registerPairingDevice(t *testing.T, store *Store) string {
	t.Helper()
	id := newID()
	if _, err := store.Register(Object{"deviceId": id, "deviceToken": randomToken()}); err != nil {
		t.Fatal(err)
	}
	return id
}

func pairWeb(t *testing.T, store *Store, id, ua string) string {
	t.Helper()
	code, err := store.Code(id)
	if err != nil {
		t.Fatal(err)
	}
	result, err := store.Complete(Object{"code": code["code"]}, ua)
	if err != nil {
		t.Fatal(err)
	}
	return result["token"].(string)
}

func pairingError(t *testing.T, err error, status int) {
	t.Helper()
	var api *apiError
	if !errors.As(err, &api) || api.Status != status {
		t.Fatalf("expected HTTP %d, got %v", status, err)
	}
}

func allowPairingControl(t *testing.T, store *Store, id, token string) string {
	t.Helper()
	permission, err := store.Permissions(id, token)
	if err != nil {
		t.Fatal(err)
	}
	screen := permission["screenId"].(string)
	if _, err := store.Permission(id, Object{"id": screen, "controlAllowed": true}); err != nil {
		t.Fatal(err)
	}
	return screen
}

func waitPairingPending(t *testing.T, store *Store, id string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		store.mu.Lock()
		ready := len(store.pending[id]) != 0
		store.mu.Unlock()
		if ready {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("command did not enter pending queue")
}

func TestPairingLegacyDatabaseAndPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pairing.sqlite")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE devices (id TEXT PRIMARY KEY, secret TEXT UNIQUE NOT NULL, name TEXT NOT NULL, code TEXT UNIQUE, expires REAL NOT NULL DEFAULT 0, seen REAL NOT NULL);
		CREATE TABLE sessions (secret TEXT PRIMARY KEY, device TEXT NOT NULL, expires REAL NOT NULL);
		CREATE TABLE screens (secret TEXT PRIMARY KEY REFERENCES sessions(secret) ON DELETE CASCADE, id TEXT UNIQUE NOT NULL, remark TEXT NOT NULL DEFAULT '', ua TEXT NOT NULL DEFAULT '', seen REAL NOT NULL DEFAULT 0);`)
	if err != nil {
		t.Fatal(err)
	}
	id, token, deviceToken := newID(), randomToken(), randomToken()
	if _, err = db.Exec("INSERT INTO devices(id,secret,name,seen) VALUES(?,?,?,?)", id, digest(deviceToken), "原设备", nowSeconds()); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO sessions VALUES(?,?,?)", digest(token), id, nowSeconds()+1000); err != nil {
		t.Fatal(err)
	}
	db.Close()
	store, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if actual, err := store.Authenticate(token, "web", "旧 Safari"); err != nil || actual != id {
		t.Fatalf("legacy session lost: %q %v", actual, err)
	}
	permission, err := store.Permissions(id, token)
	if err != nil || permission["controlAllowed"] != false {
		t.Fatalf("legacy session received control: %v %v", permission, err)
	}
	screen := allowPairingControl(t, store, id, token)
	if _, err = store.Remark(id, Object{"id": screen, "remark": " 办公室 "}); err != nil {
		t.Fatal(err)
	}
	store.Close()
	store, err = NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	permission, err = store.Permissions(id, token)
	if err != nil || permission["controlAllowed"] != true {
		t.Fatalf("explicit control permission lost after restart: %v %v", permission, err)
	}
	screens, err := store.Screens(id)
	if err != nil {
		t.Fatal(err)
	}
	item := screens["screens"].([]any)[0].(Object)
	if item["remark"] != "办公室" || item["ua"] != "旧 Safari" {
		t.Fatalf("screen metadata changed: %v", item)
	}
	var stored string
	if err = store.db.QueryRow("SELECT secret FROM sessions WHERE device=?", id).Scan(&stored); err != nil || stored != digest(token) {
		t.Fatalf("session digest changed: %q %v", stored, err)
	}
	if _, err = store.Leave(token); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = store.db.QueryRow("SELECT COUNT(*) FROM screens").Scan(&count); err != nil || count != 0 {
		t.Fatalf("foreign key cascade failed: count=%d err=%v", count, err)
	}
}

func TestPairingCodeSingleUseAndScreenLimit(t *testing.T) {
	store := newPairingStore(t)
	id := registerPairingDevice(t, store)
	code, err := store.Code(id)
	if err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := store.Complete(Object{"code": strings.ToLower(code["code"].(string))}, "")
			results <- err
		}()
	}
	group.Wait()
	close(results)
	succeeded := 0
	for err := range results {
		if err == nil {
			succeeded++
		} else {
			pairingError(t, err, 401)
		}
	}
	if succeeded != 1 {
		t.Fatalf("pairing code succeeded %d times", succeeded)
	}
	for i := 1; i < 16; i++ {
		pairWeb(t, store, id, "")
	}
	code, err = store.Code(id)
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.Complete(Object{"code": code["code"]}, "")
	pairingError(t, err, 409)
}

func TestPairingRevocationCancelsControlAndIgnoresLateAck(t *testing.T) {
	store := newPairingStore(t)
	id, target := registerPairingDevice(t, store), newID()
	token := pairWeb(t, store, id, "Safari")
	_, err := store.command(id, Object{"threadId": target}, "open", token, time.Millisecond)
	pairingError(t, err, 403)
	screen := allowPairingControl(t, store, id, token)
	other := registerPairingDevice(t, store)
	_, err = store.Permission(other, Object{"id": screen, "controlAllowed": true})
	pairingError(t, err, 404)
	if _, err = store.Exchange(id, Object{"status": Object{"conversations": []any{Object{"threadId": target}}}}); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := store.command(id, Object{"threadId": target}, "open", token, 2*time.Second)
		result <- err
	}()
	waitPairingPending(t, store, id)
	response, err := store.Exchange(id, Object{"status": Object{}})
	if err != nil {
		t.Fatal(err)
	}
	command := response["commands"].([]any)[0].(Object)
	if command["screenId"] != screen {
		t.Fatalf("missing screen identity: %v", command)
	}
	if _, err = store.Permission(id, Object{"id": screen, "controlAllowed": false}); err != nil {
		t.Fatal(err)
	}
	if _, err = store.Exchange(id, Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true}}}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		pairingError(t, err, 403)
	case <-time.After(time.Second):
		t.Fatal("permission revocation did not cancel waiting control")
	}
	if _, err = store.Authenticate(token, "web", "Safari"); err != nil {
		t.Fatalf("control revocation must preserve reading: %v", err)
	}
}

func TestPairingKickCancelsOnlyOwnedSession(t *testing.T) {
	store := newPairingStore(t)
	id := registerPairingDevice(t, store)
	first, second := pairWeb(t, store, id, "first"), pairWeb(t, store, id, "second")
	key := newID()
	if _, err := store.Exchange(id, Object{"keys": []any{Object{"id": key, "name": "测试"}}}); err != nil {
		t.Fatal(err)
	}
	permission, err := store.Permissions(id, first)
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := store.command(id, Object{"id": key}, "usage", first, 2*time.Second)
		result <- err
	}()
	waitPairingPending(t, store, id)
	if _, err = store.Kick(id, Object{"id": permission["screenId"]}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		pairingError(t, err, 401)
	case <-time.After(time.Second):
		t.Fatal("kicked session remained waiting")
	}
	if _, err = store.Authenticate(first, "web", ""); err == nil {
		t.Fatal("kicked token still authenticates")
	}
	if _, err = store.Authenticate(second, "web", "second"); err != nil {
		t.Fatalf("kick affected another session: %v", err)
	}
}

func TestPairingWaitingExchangeAndChannelIsolation(t *testing.T) {
	store := newPairingStore(t)
	id, target := registerPairingDevice(t, store), newID()
	token := pairWeb(t, store, id, "Safari")
	allowPairingControl(t, store, id, token)
	status := Object{"conversations": []any{Object{"threadId": target}}}
	responses, exchangeErrors := make(chan Object, 1), make(chan error, 1)
	go func() {
		response, err := store.Exchange(id, Object{"status": status, "waitForCommand": true})
		responses <- response
		exchangeErrors <- err
	}()
	deadline := time.Now().Add(time.Second)
	for {
		store.mu.Lock()
		ready := store.snapshots[id] != nil
		store.mu.Unlock()
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("waiting exchange did not save snapshot")
		}
		time.Sleep(time.Millisecond)
	}
	if _, err := store.Exchange(id, Object{"music": Object{"state": "idle", "enabled": false}}); err != nil {
		t.Fatal(err)
	}
	commandResult := make(chan error, 1)
	go func() {
		_, err := store.command(id, Object{"threadId": target}, "open", token, 2*time.Second)
		commandResult <- err
	}()
	var response Object
	select {
	case response = <-responses:
		if err := <-exchangeErrors; err != nil {
			t.Fatal(err)
		}
	case <-time.After(600 * time.Millisecond):
		t.Fatal("command did not wake waiting exchange promptly")
	}
	commands := response["commands"].([]any)
	if len(commands) != 1 {
		t.Fatalf("expected one command, got %v", commands)
	}
	command := commands[0].(Object)
	response, err := store.Exchange(id, Object{"status": status})
	if err != nil || len(response["commands"].([]any)) != 0 {
		t.Fatalf("command was redelivered: %v %v", response, err)
	}
	if _, err = store.Exchange(id, Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true}}}); err != nil {
		t.Fatal(err)
	}
	if err = <-commandResult; err != nil {
		t.Fatal(err)
	}
	music, err := store.Read(id, "music", "")
	if err != nil || music.(Object)["enabled"] != false {
		t.Fatalf("parallel exchange replaced newer music: %v %v", music, err)
	}
}

func TestPairingReadOnlyUsageQueriesQueue(t *testing.T) {
	store := newPairingStore(t)
	id, key := registerPairingDevice(t, store), newID()
	tokens := []string{pairWeb(t, store, id, "one"), pairWeb(t, store, id, "two")}
	if _, err := store.Exchange(id, Object{"keys": []any{Object{"id": key, "name": "测试"}}}); err != nil {
		t.Fatal(err)
	}
	results := make(chan error, 2)
	for _, token := range tokens {
		go func(token string) {
			value, err := store.command(id, Object{"id": key}, "usage", token, 2*time.Second)
			if err == nil && value["remaining"] != float64(12) {
				err = errors.New("usage result changed")
			}
			results <- err
		}(token)
	}
	completed := 0
	deadline := time.Now().Add(3 * time.Second)
	for completed < 2 && time.Now().Before(deadline) {
		response, err := store.Exchange(id, Object{"status": Object{}})
		if err != nil {
			t.Fatal(err)
		}
		for _, raw := range response["commands"].([]any) {
			command := raw.(Object)
			if _, err = store.Exchange(id, Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true, "usage": Object{"remaining": float64(12)}}}}); err != nil {
				t.Fatal(err)
			}
		}
		select {
		case err := <-results:
			if err != nil {
				t.Fatal(err)
			}
			completed++
		case <-time.After(time.Millisecond):
		}
	}
	if completed != 2 {
		t.Fatal("queued read-only queries did not finish")
	}
}

func TestPairingCommandUploadChannelsAndTimeout(t *testing.T) {
	store := newPairingStore(t)
	id, target, action := registerPairingDevice(t, store), newID(), newID()
	token := pairWeb(t, store, id, "Safari")
	allowPairingControl(t, store, id, token)
	song := Object{"state": "ready", "title": "曲目", "artist": "歌手", "source": "播放器", "lyricsState": "ready", "playing": false, "position": float64(1), "duration": float64(10), "lines": []any{}, "trackId": strings.Repeat("a", 64)}
	status := Object{"conversations": []any{Object{"threadId": target}}}
	if _, err := store.Exchange(id, Object{"status": status, "music": song, "console": []any{Object{"id": action, "name": "启动", "kind": "app", "state": "idle"}}}); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		kind, wrongChannel, rightChannel string
		value                            Object
	}{
		{"music", "status", "music", Object{"action": "play", "trackId": song["trackId"]}},
		{"console", "music", "status", Object{"id": action}},
	} {
		result := make(chan error, 1)
		go func() {
			_, err := store.command(id, test.value, test.kind, token, time.Second)
			result <- err
		}()
		waitPairingPending(t, store, id)
		values := Object{"status": status, "music": song}
		response, err := store.Exchange(id, Object{test.wrongChannel: values[test.wrongChannel]})
		if err != nil || len(response["commands"].([]any)) != 0 {
			t.Fatalf("wrong uploader consumed %s command: %v %v", test.kind, response, err)
		}
		response, err = store.Exchange(id, Object{test.rightChannel: values[test.rightChannel]})
		if err != nil || len(response["commands"].([]any)) != 1 {
			t.Fatalf("matching uploader missed %s command: %v %v", test.kind, response, err)
		}
		command := response["commands"].([]any)[0].(Object)
		if _, err = store.Exchange(id, Object{"acks": []any{Object{"requestId": command["requestId"], "ok": true}}}); err != nil {
			t.Fatal(err)
		}
		if err = <-result; err != nil {
			t.Fatal(err)
		}
	}
	_, err := store.command(id, Object{"threadId": target}, "open", token, 10*time.Millisecond)
	pairingError(t, err, 504)
	response, err := store.Exchange(id, Object{"status": status})
	if err != nil || len(response["commands"].([]any)) != 0 {
		t.Fatalf("expired command was delivered later: %v %v", response, err)
	}
}

func TestPairingSnapshotPrivacyAndFreshness(t *testing.T) {
	store := newPairingStore(t)
	id, action := registerPairingDevice(t, store), newID()
	if _, err := store.Exchange(id, Object{
		"status":  Object{"private": "secret"},
		"music":   Object{"state": "idle", "enabled": false, "layout": "full"},
		"console": []any{Object{"id": action, "name": "脚本", "kind": "script", "state": "idle", "target": "/private/test.sh", "output": "secret"}},
	}); err != nil {
		t.Fatal(err)
	}
	status, err := store.Read(id, "status", "")
	if err != nil || status.(Object)["private"] != nil {
		t.Fatalf("status leaked private field: %v %v", status, err)
	}
	console, err := store.Read(id, "console", "")
	if err != nil {
		t.Fatal(err)
	}
	item := console.([]any)[0].(Object)
	if len(item) != 5 || item["target"] != nil || item["output"] != nil {
		t.Fatalf("console leaked local data: %v", item)
	}
	store.mu.Lock()
	store.snapshots[id].consoleAt = time.Now().Add(-time.Minute)
	store.mu.Unlock()
	if _, err = store.Exchange(id, Object{"music": Object{"state": "idle"}}); err != nil {
		t.Fatal(err)
	}
	_, err = store.Read(id, "console", "")
	pairingError(t, err, 503)
	store.mu.Lock()
	store.snapshots[id].received = time.Now().Add(-time.Minute)
	store.snapshots[id].music = Object{"state": "idle", "enabled": false, "layout": "full"}
	store.mu.Unlock()
	_, err = store.Read(id, "status", "")
	pairingError(t, err, 503)
	music, err := store.Read(id, "music", "")
	if err != nil || music.(Object)["state"] != "offline" || music.(Object)["layout"] != "full" || music.(Object)["enabled"] != false {
		t.Fatalf("offline music lost layout: %v %v", music, err)
	}
}

func TestPairingCleanConsoleBoundaries(t *testing.T) {
	raw := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 40000-8)...)
	icon := "data:image/png;base64," + base64.StdEncoding.EncodeToString(raw)
	base := Object{"id": newID(), "name": "更新订阅", "kind": "subscription", "state": "idle", "icon": icon, "lastUpdatedAt": float64(1800000000)}
	result, err := cleanConsole([]any{base})
	if err != nil || result[0].(Object)["icon"] != icon {
		t.Fatalf("valid boundary rejected: %v", err)
	}
	for _, value := range []any{nil, true, "1800000000", float64(0), float64(-1), math.NaN(), math.Inf(1), float64(253402300800)} {
		item := clone(base)
		item["lastUpdatedAt"] = value
		if _, err := cleanConsole([]any{item}); err == nil {
			t.Fatalf("invalid update time accepted: %v", value)
		}
	}
	for _, value := range []string{icon + "AAAA", "data:image/png;base64," + base64.StdEncoding.EncodeToString(append(raw, 0)), "data:image/png;base64,AAAA", icon[:30] + "\n" + icon[30:]} {
		item := clone(base)
		item["icon"] = value
		if _, err := cleanConsole([]any{item}); err == nil {
			t.Fatal("invalid icon accepted")
		}
	}
	if _, err := cleanConsole([]any{base, base}); err == nil {
		t.Fatal("duplicate console identity accepted")
	}
	item := clone(base)
	item["kind"], item["lastUpdatedAt"] = "app", "must be dropped"
	result, err = cleanConsole([]any{item})
	if err != nil || result[0].(Object)["lastUpdatedAt"] != nil {
		t.Fatalf("non-subscription update field retained: %v %v", result, err)
	}
}

func TestPairingThrottleBoundary(t *testing.T) {
	store := newPairingStore(t)
	for i := 0; i < 2; i++ {
		if err := store.Throttle("peer", 2, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	pairingError(t, store.Throttle("peer", 2, time.Minute), 429)
	store.mu.Lock()
	element := store.buckets["peer"]
	bucket := element.Value.(throttleBucket)
	bucket.start = time.Now().Add(-time.Minute)
	element.Value = bucket
	store.mu.Unlock()
	if err := store.Throttle("peer", 2, time.Minute); err != nil {
		t.Fatalf("expired throttle did not reset: %v", err)
	}
	for i := 0; i < 4200; i++ {
		if err := store.Throttle(newID(), 1, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	if len(store.buckets) != 4096 || store.order.Len() != 4096 {
		t.Fatalf("throttle history is unbounded: %d", len(store.buckets))
	}
}
