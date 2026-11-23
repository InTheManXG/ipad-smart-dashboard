package main

import (
	"bytes"
	"container/list"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	_ "github.com/mattn/go-sqlite3"
)

const (
	codeTTL    = 10 * time.Minute
	sessionTTL = 30 * 24 * time.Hour
	freshTTL   = 15 * time.Second
)

var (
	pairingCodePattern    = regexp.MustCompile(`^[23456789A-HJKMNP-Z]{8}$`)
	pairingTrackIDPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

func selectFields(value Object, names ...string) Object {
	result := Object{}
	for _, name := range names {
		if item, ok := value[name]; ok {
			result[name] = item
		}
	}
	return result
}

func cleanStatus(value any) (Object, error) {
	input, ok := value.(Object)
	if !ok {
		return nil, fail(400, "invalid_snapshot")
	}
	// 白名单仅保留网页展示字段，私密配置不会随快照传出。
	result := selectFields(input, "state", "plan", "primary", "secondary", "conversationsTotal", "conversationsAvailable", "quotaAvailable", "cached", "updatedAt")
	tasks := []any{}
	if raw, exists := input["conversations"]; exists {
		var valid bool
		tasks, valid = raw.([]any)
		if !valid || len(tasks) > 8 {
			return nil, fail(400, "invalid_tasks")
		}
	}
	cleaned := make([]any, 0, len(tasks))
	for _, task := range tasks {
		item, ok := task.(Object)
		if !ok {
			return nil, fail(400, "invalid_tasks")
		}
		cleaned = append(cleaned, selectFields(item, "threadId", "title", "state", "unread", "elapsedSeconds"))
	}
	result["conversations"] = cleaned
	result["attention"] = nil
	if attention, ok := input["attention"].(Object); ok {
		result["attention"] = selectFields(attention, "threadId", "title")
		if raw, exists := attention["requestIds"]; exists {
			ids, valid := raw.([]any)
			if !valid || len(ids) > 64 {
				return nil, fail(400, "invalid_attention")
			}
			for _, value := range ids {
				id, valid := value.(string)
				if !valid || len(id) == 0 || len(id) > 200 {
					return nil, fail(400, "invalid_attention")
				}
			}
			// 只透传问题标识，供各网页独立记忆已关闭的提醒。
			result["attention"].(Object)["requestIds"] = ids
		}
	}
	result["schema"] = 1
	return result, nil
}

func cleanKeys(value any) ([]any, error) {
	input, ok := value.([]any)
	if !ok || len(input) > 50 {
		return nil, fail(400, "invalid_keys")
	}
	result := make([]any, 0, len(input))
	for _, raw := range input {
		item, ok := raw.(Object)
		if !ok {
			return nil, fail(400, "invalid_keys")
		}
		name, ok := item["name"].(string)
		if !ok || utf8.RuneCountInString(name) > 60 {
			return nil, fail(400, "invalid_keys")
		}
		id, err := validID(item["id"])
		if err != nil {
			return nil, err
		}
		usage := Object{}
		if raw, exists := item["usage"]; exists {
			usage, ok = raw.(Object)
			if !ok {
				return nil, fail(400, "invalid_usage")
			}
		}
		// 完整 Key 留在 Mac，仅转发标识、备注和额度。
		result = append(result, Object{"id": id, "name": name, "usage": selectFields(usage, "remaining", "unit", "dailyLimit", "dailyUsed", "updatedAt", "error")})
	}
	return result, nil
}

func cleanConsole(value any) ([]any, error) {
	input, ok := value.([]any)
	if !ok || len(input) > 50 {
		return nil, fail(400, "invalid_console")
	}
	result := make([]any, 0, len(input))
	ids := map[string]bool{}
	for _, raw := range input {
		item, ok := raw.(Object)
		if !ok {
			return nil, fail(400, "invalid_console")
		}
		id, err := validID(item["id"])
		if err != nil {
			return nil, err
		}
		name, ok := item["name"].(string)
		if !ok || ids[id] || utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 60 {
			return nil, fail(400, "invalid_console")
		}
		kind, _ := item["kind"].(string)
		state, _ := item["state"].(string)
		if !oneOf(kind, "app", "script", "command", "subscription") || !oneOf(state, "idle", "running", "succeeded", "failed") {
			return nil, fail(400, "invalid_console")
		}
		ids[id] = true
		icon := ""
		if raw, exists := item["icon"]; exists {
			icon, ok = raw.(string)
			if !ok || len(icon) > 53358 {
				return nil, fail(400, "invalid_icon")
			}
		}
		if icon != "" {
			const prefix = "data:image/png;base64,"
			if !strings.HasPrefix(icon, prefix) {
				return nil, fail(400, "invalid_icon")
			}
			encoded := strings.TrimPrefix(icon, prefix)
			// Go 解码器允许换行，旧协议要求严格 Base64，需额外拒绝。
			if strings.ContainsAny(encoded, "\r\n") {
				return nil, fail(400, "invalid_icon")
			}
			raw, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil || len(raw) > 40000 || !bytes.HasPrefix(raw, []byte("\x89PNG\r\n\x1a\n")) {
				return nil, fail(400, "invalid_icon")
			}
		}
		cleaned := Object{"id": id, "name": name, "kind": kind, "state": state, "icon": icon}
		if updated, exists := item["lastUpdatedAt"]; kind == "subscription" && exists {
			stamp, ok := number(updated)
			if !ok || stamp <= 0 || stamp > 253402300799 || math.IsNaN(stamp) || math.IsInf(stamp, 0) {
				return nil, fail(400, "invalid_console")
			}
			cleaned["lastUpdatedAt"] = updated
		}
		// 命令、路径和脚本输出不进入中继快照。
		result = append(result, cleaned)
	}
	return result, nil
}

func oneOf(value string, choices ...string) bool {
	for _, choice := range choices {
		if value == choice {
			return true
		}
	}
	return false
}

type storeQuery interface {
	Exec(string, ...any) (sql.Result, error)
	Query(string, ...any) (*sql.Rows, error)
	QueryRow(string, ...any) *sql.Row
}

type deviceSnapshot struct {
	received  time.Time
	status    Object
	music     Object
	keys      []any
	console   []any
	consoleAt time.Time
}

type pendingCommand struct {
	payload  Object
	deadline time.Time
	sent     bool
	result   Object
	owner    string
}

type throttleBucket struct {
	key   string
	count int
	start time.Time
}

type Store struct {
	db        *sql.DB
	mu        sync.Mutex
	changed   chan struct{}
	snapshots map[string]*deviceSnapshot
	pending   map[string]map[string]*pendingCommand
	buckets   map[string]*list.Element
	order     *list.List
}

func NewStore(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	if err = os.Chmod(path, 0600); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		return nil, err
	}
	// 与旧版单连接一致，外键设置和事务不能被连接池切换绕过。
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(`PRAGMA foreign_keys=ON;
		CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, secret TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
		code TEXT UNIQUE, expires REAL NOT NULL DEFAULT 0, seen REAL NOT NULL);
		CREATE TABLE IF NOT EXISTS sessions (secret TEXT PRIMARY KEY, device TEXT NOT NULL, expires REAL NOT NULL);
		CREATE TABLE IF NOT EXISTS screens (secret TEXT PRIMARY KEY REFERENCES sessions(secret) ON DELETE CASCADE,
		id TEXT UNIQUE NOT NULL, remark TEXT NOT NULL DEFAULT '', ua TEXT NOT NULL DEFAULT '', seen REAL NOT NULL DEFAULT 0,
		control_allowed INTEGER NOT NULL DEFAULT 0);`); err != nil {
		db.Close()
		return nil, err
	}
	rows, err := db.Query("PRAGMA table_info(screens)")
	if err != nil {
		db.Close()
		return nil, err
	}
	found := false
	for rows.Next() {
		var cid, notnull, pk int
		var name, kind string
		var defaultValue any
		if err = rows.Scan(&cid, &name, &kind, &notnull, &defaultValue, &pk); err != nil {
			break
		}
		found = found || name == "control_allowed"
	}
	if err == nil {
		err = rows.Err()
	}
	if closeErr := rows.Close(); err == nil {
		err = closeErr
	}
	if err == nil && !found {
		// 旧会话继续可读，但升级不能默认授予控制权限。
		_, err = db.Exec("ALTER TABLE screens ADD COLUMN control_allowed INTEGER NOT NULL DEFAULT 0")
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db, changed: make(chan struct{}), snapshots: map[string]*deviceSnapshot{}, pending: map[string]map[string]*pendingCommand{}, buckets: map[string]*list.Element{}, order: list.New()}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) notifyLocked() {
	close(s.changed)
	s.changed = make(chan struct{})
}

// 等待必须释放互斥锁，否则上传、撤权和回执均无法唤醒调用方。
func (s *Store) waitLocked(deadline time.Time, ready func() bool) bool {
	for !ready() {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return ready()
		}
		changed := s.changed
		s.mu.Unlock()
		timer := time.NewTimer(remaining)
		select {
		case <-changed:
		case <-timer.C:
		}
		timer.Stop()
		s.mu.Lock()
	}
	return true
}

func (s *Store) Throttle(key string, maximum int, period time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	var bucket throttleBucket
	if element := s.buckets[key]; element != nil {
		bucket = element.Value.(throttleBucket)
		s.order.Remove(element)
	}
	if bucket.start.IsZero() || now.Sub(bucket.start) >= period {
		bucket = throttleBucket{key: key, start: now}
	}
	previous := bucket.count
	bucket.count++
	s.buckets[key] = s.order.PushBack(bucket)
	for s.order.Len() > 4096 {
		oldest := s.order.Front()
		delete(s.buckets, oldest.Value.(throttleBucket).key)
		s.order.Remove(oldest)
	}
	if previous >= maximum {
		return fail(429, "too_many_requests")
	}
	return nil
}

func nowSeconds() float64 { return float64(time.Now().UnixNano()) / 1e9 }

func (s *Store) stateLocked(db storeQuery, id string) (Object, error) {
	var name string
	var expiry float64
	if err := db.QueryRow("SELECT name,expires FROM devices WHERE id=?", id).Scan(&name, &expiry); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, fail(401, "unauthorized")
		}
		return nil, err
	}
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM sessions WHERE device=? AND expires>?", id, nowSeconds()).Scan(&count); err != nil {
		return nil, err
	}
	return Object{"paired": count > 0, "screenCount": count, "name": name, "expiresAt": expiry}, nil
}

func (s *Store) Register(value Object) (Object, error) {
	id, err := validID(value["deviceId"])
	if err != nil {
		return nil, err
	}
	token, err := credential(value["deviceToken"])
	if err != nil {
		return nil, err
	}
	name := "Mac App"
	if raw, exists := value["name"]; exists {
		var valid bool
		name, valid = raw.(string)
		if !valid {
			return nil, fail(400, "invalid_name")
		}
	}
	if utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 80 {
		return nil, fail(400, "invalid_name")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var stored string
	err = tx.QueryRow("SELECT secret FROM devices WHERE id=?", id).Scan(&stored)
	if errors.Is(err, sql.ErrNoRows) {
		now := nowSeconds()
		if _, err = tx.Exec("DELETE FROM sessions WHERE expires < ?", now); err != nil {
			return nil, err
		}
		if _, err = tx.Exec("DELETE FROM devices WHERE seen < ? AND id NOT IN (SELECT device FROM sessions)", now-86400); err != nil {
			return nil, err
		}
		var count int
		if err = tx.QueryRow("SELECT COUNT(*) FROM devices").Scan(&count); err != nil {
			return nil, err
		}
		if count >= 10000 {
			return nil, fail(503, "capacity_reached")
		}
		if _, err = tx.Exec("INSERT INTO devices(id,secret,name,seen) VALUES(?,?,?,?)", id, token, name, now); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	} else if stored != token {
		return nil, fail(401, "unauthorized")
	}
	if _, err = tx.Exec("UPDATE devices SET name=?,seen=? WHERE id=?", name, nowSeconds(), id); err != nil {
		return nil, err
	}
	result, err := s.stateLocked(tx, id)
	if err != nil {
		return nil, err
	}
	return result, tx.Commit()
}

func (s *Store) State(id string) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stateLocked(s.db, id)
}

func (s *Store) screenLocked(db storeQuery, hashed string, ua *string) error {
	if _, err := db.Exec("INSERT OR IGNORE INTO screens(secret,id) VALUES(?,?)", hashed, newID()); err != nil {
		return err
	}
	if ua != nil {
		runes := []rune(*ua)
		if len(runes) > 1024 {
			runes = runes[:1024]
		}
		agent, now := string(runes), nowSeconds()
		_, err := db.Exec("UPDATE screens SET ua=?,seen=? WHERE secret=? AND (ua!=? OR seen<?)", agent, now, hashed, agent, now-60)
		return err
	}
	return nil
}

func (s *Store) authenticateLocked(token, role string, ua *string) (string, error) {
	hashed, err := credential(token)
	if err != nil {
		return "", err
	}
	var id string
	if role == "device" {
		err = s.db.QueryRow("SELECT id FROM devices WHERE secret=?", hashed).Scan(&id)
	} else {
		err = s.db.QueryRow("SELECT device FROM sessions WHERE secret=? AND expires>?", hashed, nowSeconds()).Scan(&id)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", fail(401, "unauthorized")
	}
	if err != nil {
		return "", err
	}
	if role == "web" {
		if err = s.screenLocked(s.db, hashed, ua); err != nil {
			return "", err
		}
	}
	return id, nil
}

func (s *Store) Authenticate(token, role, ua string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// 回包前复核不带浏览器信息，不能清空首次认证保存的 UA。
	if ua == "" {
		return s.authenticateLocked(token, role, nil)
	}
	return s.authenticateLocked(token, role, &ua)
}

func (s *Store) permissionsLocked(id, token string) (Object, error) {
	hashed, err := credential(token)
	if err != nil {
		return nil, err
	}
	var screenID string
	var allowed bool
	err = s.db.QueryRow("SELECT c.id,c.control_allowed FROM screens c JOIN sessions s ON c.secret=s.secret WHERE s.secret=? AND s.device=? AND s.expires>?", hashed, id, nowSeconds()).Scan(&screenID, &allowed)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(401, "unauthorized")
	}
	if err != nil {
		return nil, err
	}
	return Object{"screenId": screenID, "controlAllowed": allowed}, nil
}

func (s *Store) Permissions(id, token string) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.permissionsLocked(id, token)
}

func (s *Store) Screens(id string) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query("SELECT secret FROM sessions WHERE device=? AND expires>?", id, nowSeconds())
	if err != nil {
		return nil, err
	}
	secrets := []string{}
	for rows.Next() {
		var secret string
		if err = rows.Scan(&secret); err != nil {
			break
		}
		secrets = append(secrets, secret)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	for _, secret := range secrets {
		if err = s.screenLocked(tx, secret, nil); err != nil {
			return nil, err
		}
	}
	rows, err = tx.Query("SELECT c.id,c.remark,c.ua,c.seen,s.expires,c.control_allowed FROM screens c JOIN sessions s ON c.secret=s.secret WHERE s.device=? AND s.expires>? ORDER BY c.seen DESC,c.id", id, nowSeconds())
	if err != nil {
		return nil, err
	}
	result := []any{}
	for rows.Next() {
		var screenID, remark, ua string
		var seen, expiry float64
		var allowed bool
		if err = rows.Scan(&screenID, &remark, &ua, &seen, &expiry, &allowed); err != nil {
			break
		}
		result = append(result, Object{"id": screenID, "remark": remark, "ua": ua, "seen": seen, "expires": expiry, "controlAllowed": allowed})
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	return Object{"screens": result}, tx.Commit()
}

func (s *Store) Permission(id string, value Object) (Object, error) {
	screenID, err := validID(value["id"])
	if err != nil {
		return nil, err
	}
	allowed, ok := value["controlAllowed"].(bool)
	if !ok {
		return nil, fail(400, "invalid_permission")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var secret string
	err = s.db.QueryRow("SELECT c.secret FROM screens c JOIN sessions s ON c.secret=s.secret WHERE c.id=? AND s.device=? AND s.expires>?", screenID, id, nowSeconds()).Scan(&secret)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(404, "screen_not_found")
	}
	if err != nil {
		return nil, err
	}
	if _, err = s.db.Exec("UPDATE screens SET control_allowed=? WHERE secret=?", allowed, secret); err != nil {
		return nil, err
	}
	if !allowed {
		// 撤权立即终止控制等待，只读额度查询不受影响。
		for _, command := range s.pending[id] {
			if command.owner == secret && command.payload["kind"] != "usage" {
				command.result = Object{"ok": false, "error": "control_not_allowed"}
			}
		}
		s.notifyLocked()
	}
	return Object{"ok": true}, nil
}

func (s *Store) Remark(id string, value Object) (Object, error) {
	screenID, err := validID(value["id"])
	if err != nil {
		return nil, err
	}
	note, ok := value["remark"].(string)
	note = strings.TrimSpace(note)
	if !ok || utf8.RuneCountInString(note) > 80 {
		return nil, fail(400, "invalid_remark")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result, err := s.db.Exec("UPDATE screens SET remark=? WHERE id=? AND secret IN (SELECT secret FROM sessions WHERE device=? AND expires>?)", note, screenID, id, nowSeconds())
	if err != nil {
		return nil, err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if changed == 0 {
		return nil, fail(404, "screen_not_found")
	}
	return Object{"ok": true}, nil
}

func (s *Store) Code(id string) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	const alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
	var raw string
	for {
		code := make([]byte, 8)
		for i := range code {
			n, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
			if err != nil {
				return nil, err
			}
			code[i] = alphabet[n.Int64()]
		}
		raw = string(code)
		var exists int
		err = tx.QueryRow("SELECT 1 FROM devices WHERE code=?", digest(raw)).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	expiry := nowSeconds() + codeTTL.Seconds()
	if _, err = tx.Exec("UPDATE devices SET code=?,expires=?,seen=? WHERE id=?", digest(raw), expiry, nowSeconds(), id); err != nil {
		return nil, err
	}
	result, err := s.stateLocked(tx, id)
	if err != nil {
		return nil, err
	}
	result["code"], result["expiresAt"] = raw, expiry
	return result, tx.Commit()
}

func (s *Store) Complete(value Object, ua string) (Object, error) {
	code, ok := value["code"].(string)
	code = strings.ToUpper(code)
	if !ok || !pairingCodePattern.MatchString(code) {
		return nil, fail(401, "invalid_pairing_code")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var id, name string
	err = tx.QueryRow("SELECT id,name FROM devices WHERE code=? AND expires>?", digest(code), nowSeconds()).Scan(&id, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(401, "invalid_pairing_code")
	}
	if err != nil {
		return nil, err
	}
	state, err := s.stateLocked(tx, id)
	if err != nil {
		return nil, err
	}
	if state["screenCount"].(int) >= 16 {
		return nil, fail(409, "screen_limit")
	}
	token := randomToken()
	if _, err = tx.Exec("INSERT INTO sessions VALUES(?,?,?)", digest(token), id, nowSeconds()+sessionTTL.Seconds()); err != nil {
		return nil, err
	}
	if err = s.screenLocked(tx, digest(token), &ua); err != nil {
		return nil, err
	}
	// 消费配对码与写会话同一事务，同一码并发提交最多一个成功。
	if _, err = tx.Exec("UPDATE devices SET code=NULL,expires=0 WHERE id=?", id); err != nil {
		return nil, err
	}
	return Object{"token": token, "name": name}, tx.Commit()
}

func (s *Store) Revoke(id string) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("DELETE FROM sessions WHERE device=?", id); err != nil {
		return nil, err
	}
	if _, err = tx.Exec("UPDATE devices SET code=NULL,expires=0 WHERE id=?", id); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	for _, command := range s.pending[id] {
		command.result = Object{"ok": false, "error": "revoked"}
	}
	s.notifyLocked()
	delete(s.snapshots, id)
	return Object{"ok": true}, nil
}

func (s *Store) removeSessionLocked(hashed string) error {
	if _, err := s.db.Exec("DELETE FROM sessions WHERE secret=?", hashed); err != nil {
		return err
	}
	for _, commands := range s.pending {
		for _, command := range commands {
			if command.owner == hashed {
				command.result = Object{"ok": false, "error": "revoked"}
			}
		}
	}
	s.notifyLocked()
	return nil
}

func (s *Store) Kick(id string, value Object) (Object, error) {
	screenID, err := validID(value["id"])
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var secret string
	err = s.db.QueryRow("SELECT s.secret FROM sessions s JOIN screens c ON c.secret=s.secret WHERE c.id=? AND s.device=? AND s.expires>?", screenID, id, nowSeconds()).Scan(&secret)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(404, "screen_not_found")
	}
	if err != nil {
		return nil, err
	}
	if err = s.removeSessionLocked(secret); err != nil {
		return nil, err
	}
	return Object{"ok": true}, nil
}

func (s *Store) Leave(token string) (Object, error) {
	hashed, err := credential(token)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err = s.removeSessionLocked(hashed); err != nil {
		return nil, err
	}
	return Object{"ok": true}, nil
}

func (s *Store) Exchange(id string, value Object) (Object, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous := s.snapshots[id]
	status, song := Object{"schema": 1, "conversations": []any{}}, Object{"state": "offline"}
	keys, console := []any{}, []any{}
	consoleAt := time.Time{}
	if previous != nil {
		status, song, keys, console, consoleAt = previous.status, previous.music, previous.keys, previous.console, previous.consoleAt
	}
	var err error
	if raw, exists := value["status"]; exists {
		status, err = cleanStatus(raw)
		if err != nil {
			return nil, err
		}
	}
	if raw, exists := value["music"]; exists {
		song, err = validateMusic(raw)
	} else {
		song, err = validateMusic(song)
	}
	if err != nil {
		return nil, err
	}
	if raw, exists := value["keys"]; exists {
		keys, err = cleanKeys(raw)
		if err != nil {
			return nil, err
		}
	}
	if raw, exists := value["console"]; exists {
		console, err = cleanConsole(raw)
		if err != nil {
			return nil, err
		}
		consoleAt = time.Now()
	}
	acks := []any{}
	if raw, exists := value["acks"]; exists {
		var ok bool
		acks, ok = raw.([]any)
		if !ok || len(acks) > 8 {
			return nil, fail(400, "invalid_acks")
		}
	}
	for _, raw := range acks {
		ack, ok := raw.(Object)
		if !ok {
			return nil, fail(400, "invalid_acks")
		}
		if _, ok = ack["ok"].(bool); !ok {
			return nil, fail(400, "invalid_acks")
		}
	}
	now := time.Now()
	s.snapshots[id] = &deviceSnapshot{now, status, song, keys, console, consoleAt}
	// 断线快照只短期保留，历史设备数量不会无限占用内存。
	for key, snapshot := range s.snapshots {
		if now.Sub(snapshot.received) > time.Minute {
			delete(s.snapshots, key)
		}
	}
	for _, raw := range acks {
		ack := raw.(Object)
		requestID, _ := ack["requestId"].(string)
		command := s.pending[id][requestID]
		if command != nil && command.deadline.After(now) && command.result == nil {
			command.result = Object{"ok": ack["ok"]}
			if command.payload["kind"] == "music" {
				command.result["snapshot"] = song
			}
			if usage, ok := ack["usage"].(Object); command.payload["kind"] == "usage" && ok {
				command.result["usage"] = usage
			}
		}
	}
	_, hasStatus := value["status"]
	if value["waitForCommand"] == true && hasStatus && len(acks) == 0 {
		s.waitLocked(time.Now().Add(800*time.Millisecond), func() bool {
			for _, command := range s.pending[id] {
				if command.payload["kind"] != "music" && !command.sent && command.result == nil && command.deadline.After(time.Now()) {
					return true
				}
			}
			return false
		})
	}
	now = time.Now()
	commands := []any{}
	for requestID, command := range s.pending[id] {
		channel := "status"
		if command.payload["kind"] == "music" {
			channel = "music"
		}
		if _, exists := value[channel]; !exists {
			continue
		}
		if command.deadline.After(now) && !command.sent && command.result == nil {
			command.sent = true
			payload := clone(command.payload)
			payload["requestId"], payload["expiresIn"] = requestID, command.deadline.Sub(now).Seconds()
			commands = append(commands, payload)
		}
	}
	s.notifyLocked()
	state, err := s.stateLocked(s.db, id)
	if err != nil {
		return nil, err
	}
	state["commands"] = commands
	return state, nil
}

func (s *Store) readLocked(id, kind, key string) (any, error) {
	item, now := s.snapshots[id], time.Now()
	if item == nil || now.Sub(item.received) > freshTTL {
		if kind == "music" {
			enabled, layout := false, any("standard")
			if item != nil {
				enabled = true
				if value, exists := item.music["enabled"]; exists {
					enabled, _ = value.(bool)
				}
				if value, exists := item.music["layout"]; exists {
					layout = value
				}
			}
			return Object{"state": "offline", "enabled": enabled, "layout": layout}, nil
		}
		return nil, fail(503, "device_offline")
	}
	switch kind {
	case "status":
		result := clone(item.status)
		result["servedAt"] = nowSeconds()
		return result, nil
	case "music":
		result := clone(item.music)
		if result["playing"] == true {
			duration, _ := number(result["duration"])
			position, _ := number(result["position"])
			result["position"] = math.Min(duration, position+now.Sub(item.received).Seconds())
		}
		return result, nil
	case "console":
		if now.Sub(item.consoleAt) > freshTTL {
			return nil, fail(503, "device_offline")
		}
		return item.console, nil
	case "keys":
		result := make([]any, 0, len(item.keys))
		for _, raw := range item.keys {
			result = append(result, selectFields(raw.(Object), "id", "name"))
		}
		return result, nil
	default:
		for _, raw := range item.keys {
			record := raw.(Object)
			if record["id"] == key {
				return record["usage"], nil
			}
		}
		return nil, fail(404, "key_not_found")
	}
}

func (s *Store) Read(id, kind, key string) (any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readLocked(id, kind, key)
}

func (s *Store) Command(id string, value Object, kind, token string) (Object, error) {
	return s.command(id, value, kind, token, 8*time.Second)
}

func (s *Store) command(id string, value Object, kind, token string, wait time.Duration) (Object, error) {
	if !oneOf(kind, "open", "music", "console", "usage") {
		return nil, fail(404, "unsupported")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	checkAccess := func() (Object, error) {
		actual, err := s.authenticateLocked(token, "web", nil)
		if err != nil {
			return nil, err
		}
		if actual != id {
			return nil, fail(401, "unauthorized")
		}
		permission, err := s.permissionsLocked(id, token)
		if err != nil {
			return nil, err
		}
		if kind != "usage" && permission["controlAllowed"] != true {
			return nil, fail(403, "control_not_allowed")
		}
		return permission, nil
	}
	if _, err := checkAccess(); err != nil {
		return nil, err
	}
	payload := Object{"kind": kind}
	switch kind {
	case "open":
		target, err := validID(value["threadId"])
		if err != nil {
			return nil, err
		}
		raw, err := s.readLocked(id, "status", "")
		if err != nil {
			return nil, err
		}
		status := raw.(Object)
		allowed := false
		for _, raw := range status["conversations"].([]any) {
			allowed = allowed || raw.(Object)["threadId"] == target
		}
		if attention, ok := status["attention"].(Object); ok {
			allowed = allowed || attention["threadId"] == target
		}
		if !allowed {
			return nil, fail(409, "stale_target")
		}
		payload["threadId"] = target
	case "music":
		action, _ := value["action"].(string)
		trackID, _ := value["trackId"].(string)
		if !oneOf(action, "previous", "replay", "play", "pause", "next") || !pairingTrackIDPattern.MatchString(trackID) {
			return nil, fail(400, "invalid_command")
		}
		raw, err := s.readLocked(id, "music", "")
		if err != nil {
			return nil, err
		}
		song := raw.(Object)
		if song["state"] != "ready" || song["trackId"] != trackID {
			return nil, fail(409, "stale_target")
		}
		payload["action"], payload["trackId"] = action, trackID
	case "console":
		if len(value) != 1 {
			return nil, fail(400, "invalid_command")
		}
		target, err := validID(value["id"])
		if err != nil {
			return nil, err
		}
		raw, err := s.readLocked(id, "console", "")
		if err != nil {
			return nil, err
		}
		found, busy := false, false
		for _, raw := range raw.([]any) {
			item := raw.(Object)
			found, busy = found || item["id"] == target, busy || item["state"] == "running"
		}
		if !found {
			return nil, fail(404, "action_not_found")
		}
		if busy {
			return nil, fail(409, "device_busy")
		}
		payload["id"] = target
	case "usage":
		key, _ := value["id"].(string)
		if _, err := s.readLocked(id, "usage", key); err != nil {
			return nil, err
		}
		payload["id"] = key
	}
	if kind == "usage" && !s.waitLocked(time.Now().Add(wait), func() bool { return len(s.pending[id]) == 0 }) {
		return nil, fail(409, "device_busy")
	}
	permission, err := checkAccess()
	if err != nil {
		return nil, err
	}
	payload["screenId"] = permission["screenId"]
	if len(s.pending[id]) != 0 {
		return nil, fail(409, "device_busy")
	}
	hashed, err := credential(token)
	if err != nil {
		return nil, err
	}
	requestID := newID()
	command := &pendingCommand{payload: payload, deadline: time.Now().Add(wait), owner: hashed}
	s.pending[id] = map[string]*pendingCommand{requestID: command}
	s.notifyLocked()
	defer func() {
		delete(s.pending, id)
		s.notifyLocked()
	}()
	if !s.waitLocked(command.deadline, func() bool { return command.result != nil }) {
		return nil, fail(504, "unconfirmed")
	}
	// 回执不能恢复已经撤销的会话或控制权限。
	if _, err := checkAccess(); err != nil {
		return nil, err
	}
	if command.result["ok"] != true {
		return nil, fail(409, "unconfirmed")
	}
	if usage, ok := command.result["usage"].(Object); ok {
		return usage, nil
	}
	return command.result, nil
}
