package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

type server struct {
	store       *Store
	music       *Music
	relay       *Relay
	root, token string
	client      *http.Client
}

// 旧客户端依赖失败响应中的 ok/error 字段，迁移时连同状态码保留。
type httpResult struct {
	status int
	value  any
}

func newServer(root, dataDir, mode string) (*server, error) {
	s := &server{root: root, music: NewMusic(), relay: NewRelay(dataDir), client: &http.Client{Timeout: 15 * time.Second}}
	switch mode {
	case "pairing":
		var err error
		s.store, err = NewStore(filepath.Join(dataDir, "pairing.sqlite"))
		if err != nil {
			return nil, err
		}
	case "legacy":
		path := filepath.Join(root, ".display-token")
		value, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			file, createErr := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if createErr != nil {
				return nil, createErr
			}
			value = []byte(randomToken())
			_, err = file.Write(value)
			closeErr := file.Close()
			if err == nil {
				err = closeErr
			}
		}
		if err != nil {
			return nil, err
		}
		s.token = strings.TrimSpace(string(value))
		if s.token == "" {
			return nil, errors.New("管理口令文件为空")
		}
	default:
		return nil, errors.New("不支持的 DISPLAY_MODE")
	}
	return s, nil
}

var staticFiles = map[string][2]string{
	"/": {"index.html", "text/html"}, "/app.js": {"app.js", "text/javascript"},
	"/relay.js": {"relay.js", "text/javascript"}, "/music.js": {"music.js", "text/javascript"},
	"/console.js": {"console.js", "text/javascript"}, "/style.css": {"style.css", "text/css"},
	"/manifest.json": {"manifest.json", "application/manifest+json"},
	"/icon.svg":      {"icon.svg", "image/svg+xml"}, "/app-icon.png": {"app-icon.png", "image/png"},
	"/music-note.svg": {"music-note.svg", "image/png"},
}

func reply(w http.ResponseWriter, status int, body []byte, kind string) {
	w.Header().Set("Content-Type", kind+"; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func replyJSON(w http.ResponseWriter, value any, err error) {
	status := http.StatusOK
	if result, ok := value.(httpResult); ok {
		status, value = result.status, result.value
	}
	if err != nil {
		var problem *apiError
		if errors.As(err, &problem) {
			status, value = problem.Status, Object{"error": problem.Message}
		} else {
			// 不将数据库路径、上游地址或凭据错误内容传给网页。
			status, value = http.StatusServiceUnavailable, Object{"error": "storage_unavailable"}
		}
	}
	body, err := json.Marshal(value)
	if err != nil {
		status, body = 500, []byte(`{"error":"invalid_response"}`)
	}
	reply(w, status, body, "application/json")
}

func readBody(w http.ResponseWriter, r *http.Request, limit int64) (Object, error) {
	if len(r.TransferEncoding) != 0 {
		return nil, fail(400, "invalid_body")
	}
	if r.ContentLength <= 0 || r.ContentLength > limit {
		return nil, fail(413, "body_too_large")
	}
	// 限制读取时间和字节数，等待控制回执时则不再占用请求体读取期限。
	controller := http.NewResponseController(w)
	_ = controller.SetReadDeadline(time.Now().Add(8 * time.Second))
	defer controller.SetReadDeadline(time.Time{})
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil || int64(len(raw)) != r.ContentLength || !utf8.Valid(raw) {
		return nil, fail(400, "invalid_body")
	}
	var value Object
	if json.Unmarshal(raw, &value) != nil || value == nil {
		return nil, fail(400, "invalid_body")
	}
	return value, nil
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" && r.Method != "POST" {
		replyJSON(w, nil, fail(405, "method_not_allowed"))
		return
	}
	if r.URL.Path == "/api/mode" {
		mode := "legacy"
		if s.store != nil {
			mode = "pairing"
		}
		replyJSON(w, Object{"mode": mode}, nil)
		return
	}
	if s.store != nil && strings.HasPrefix(r.URL.Path, "/api/") {
		value, err := s.pairingAPI(w, r)
		replyJSON(w, value, err)
		return
	}
	if r.Method == "GET" {
		// 只提供固定资源，不允许路径穿越或访问同目录的凭据。
		if file, ok := staticFiles[r.URL.RequestURI()]; ok {
			body, err := os.ReadFile(filepath.Join(s.root, "web", file[0]))
			if err != nil {
				replyJSON(w, nil, err)
			} else {
				reply(w, 200, body, file[1])
			}
			return
		}
	}
	if s.store == nil {
		value, err := s.legacyAPI(w, r)
		replyJSON(w, value, err)
		return
	}
	reply(w, 404, []byte("Not found"), "text/plain")
}

func (s *server) pairingAPI(w http.ResponseWriter, r *http.Request) (any, error) {
	path, method := r.URL.Path, r.Method
	value := Object{}
	if method == "POST" {
		limit := int64(1024)
		if path == "/api/device/exchange" {
			limit = 3200000
		}
		var err error
		value, err = readBody(w, r, limit)
		if err != nil {
			return nil, err
		}
	}
	peer, _, _ := net.SplitHostPort(r.RemoteAddr)
	if os.Getenv("PAIRING_TRUST_PROXY") == "1" && (peer == "127.0.0.1" || peer == "::1") {
		if forwarded := r.Header.Get("X-Real-IP"); forwarded != "" {
			peer = forwarded
		}
	}
	if method == "POST" && path == "/api/pairing/register" {
		if err := s.store.Throttle("register:"+peer, 10, 600*time.Second); err != nil {
			return nil, err
		}
		if err := s.store.Throttle("register-global", 100, 600*time.Second); err != nil {
			return nil, err
		}
		return s.store.Register(value)
	}
	if method == "POST" && path == "/api/pairing/complete" {
		if err := s.store.Throttle("complete:"+peer, 10, time.Minute); err != nil {
			return nil, err
		}
		if err := s.store.Throttle("complete-global", 300, time.Minute); err != nil {
			return nil, err
		}
		return s.store.Complete(value, r.UserAgent())
	}
	switch path {
	case "/api/device/exchange", "/api/pairing/code", "/api/pairing/revoke", "/api/pairing/device", "/api/pairing/screens", "/api/pairing/screen", "/api/pairing/kick", "/api/pairing/permission":
		id, err := s.store.Authenticate(r.Header.Get("X-Device-Token"), "device", "")
		if err != nil {
			return nil, err
		}
		if err := s.store.Throttle("device:"+id, 600, time.Minute); err != nil {
			return nil, err
		}
		switch {
		case path == "/api/device/exchange" && method == "POST":
			return s.store.Exchange(id, value)
		case path == "/api/pairing/code" && method == "POST":
			return s.store.Code(id)
		case path == "/api/pairing/revoke" && method == "POST":
			return s.store.Revoke(id)
		case path == "/api/pairing/device" && method == "GET":
			return s.store.State(id)
		case path == "/api/pairing/screens" && method == "GET":
			return s.store.Screens(id)
		case path == "/api/pairing/screen" && method == "POST":
			return s.store.Remark(id, value)
		case path == "/api/pairing/kick" && method == "POST":
			return s.store.Kick(id, value)
		case path == "/api/pairing/permission" && method == "POST":
			return s.store.Permission(id, value)
		default:
			return nil, fail(405, "method_not_allowed")
		}
	}
	token := r.Header.Get("X-Pairing-Token")
	id, err := s.store.Authenticate(token, "web", r.UserAgent())
	if err != nil {
		return nil, err
	}
	if err := s.store.Throttle("web:"+digest(token), 360, time.Minute); err != nil {
		return nil, err
	}
	var result any
	switch {
	case path == "/api/pairing/leave" && method == "POST":
		return s.store.Leave(token)
	case path == "/api/pairing/status" && method == "GET":
		result, err = s.store.State(id)
	case path == "/api/permissions" && method == "GET":
		result, err = s.store.Permissions(id, token)
	case (path == "/api/status" || path == "/api/music") && method == "GET":
		result, err = s.store.Read(id, strings.TrimPrefix(path, "/api/"), "")
		if err == nil {
			var permission Object
			permission, err = s.store.Permissions(id, token)
			if err == nil {
				copy := clone(result.(Object))
				for key, value := range permission {
					copy[key] = value
				}
				result = copy
			}
		}
	case path == "/api/console" && method == "GET":
		result, err = s.store.Read(id, "console", "")
	case path == "/api/console/run" && method == "POST":
		result, err = s.store.Command(id, value, "console", token)
	case path == "/api/relay/keys" && method == "GET":
		result, err = s.store.Read(id, "keys", "")
	case path == "/api/relay/usage" && method == "GET":
		query := r.URL.Query()
		if refresh := query["refresh"]; len(refresh) == 1 && refresh[0] == "1" {
			result, err = s.store.Command(id, Object{"id": query.Get("id")}, "usage", token)
		} else {
			result, err = s.store.Read(id, "usage", query.Get("id"))
		}
	case path == "/api/open" && method == "POST":
		result, err = s.store.Command(id, value, "open", token)
	case path == "/api/music/control" && method == "POST":
		result, err = s.store.Command(id, value, "music", token)
	default:
		return nil, fail(404, "unsupported")
	}
	if err != nil {
		return nil, err
	}
	// 读取和长轮询结束后再检查撤销，过期会话不能拿到途中产生的结果。
	if current, err := s.store.Authenticate(token, "web", r.UserAgent()); err != nil || current != id {
		return nil, fail(401, "unauthorized")
	}
	return result, nil
}

func (s *server) legacyAPI(w http.ResponseWriter, r *http.Request) (any, error) {
	path, method := r.URL.Path, r.Method
	relayRoute := path == "/api/relay/keys" || (path == "/api/relay/usage" && method == "GET")
	known := relayRoute || path == "/api/status" && method == "GET" || path == "/api/permissions" && method == "GET" || path == "/api/music" || path == "/api/music/control" && method == "POST" || path == "/api/music/ack" && method == "POST" || path == "/api/open" && method == "POST"
	if !known {
		return nil, fail(404, "unsupported")
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Display-Token")), []byte(s.token)) != 1 {
		return httpResult{401, Object{}}, nil
	}
	value := Object{}
	if method == "POST" {
		limit := int64(512)
		if path == "/api/relay/keys" {
			limit = 4096
		}
		if path == "/api/music" {
			limit = 512000
		}
		if path == "/api/open" {
			limit = 256
		}
		var err error
		value, err = readBody(w, r, limit)
		if err != nil {
			if !relayRoute {
				return httpResult{400, Object{}}, nil
			}
			return nil, fail(400, "invalid_request")
		}
	}
	if relayRoute {
		if method == "POST" {
			return s.relay.ChangeKey(value)
		}
		if path == "/api/relay/keys" {
			return s.relay.PublicKeys()
		}
		query := r.URL.Query()
		refresh := query["refresh"]
		return s.relay.ReadUsage(query.Get("id"), len(refresh) == 1 && refresh[0] == "1")
	}
	switch path {
	case "/api/permissions":
		return Object{"controlAllowed": true}, nil
	case "/api/status":
		status, err := s.readStatus()
		if err != nil {
			return nil, fail(503, "bridge_unavailable")
		}
		status["controlAllowed"] = true
		return status, nil
	case "/api/music":
		if method == "GET" {
			result := s.music.Get()
			result["controlAllowed"] = true
			return result, nil
		}
		if err := s.music.Put(value); err != nil {
			return httpResult{400, Object{}}, nil
		}
		wait := 200 * time.Millisecond
		if ack, ok := value["ack"]; ok {
			if err := s.music.Acknowledge(ack); err != nil {
				return httpResult{400, Object{}}, nil
			}
			wait = 0
		}
		return Object{"ok": true, "command": s.music.PendingControl(wait)}, nil
	case "/api/music/ack":
		if err := s.music.Acknowledge(value); err != nil {
			return httpResult{400, Object{}}, nil
		}
		return Object{"ok": true}, nil
	case "/api/music/control":
		result, err := s.music.Control(value)
		if err != nil {
			return httpResult{400, Object{}}, nil
		}
		if result["ok"] != true {
			return httpResult{409, result}, nil
		}
		result["snapshot"] = s.music.Get()
		return result, nil
	case "/api/open":
		id, err := validID(value["threadId"])
		if err != nil {
			return httpResult{400, Object{}}, nil
		}
		ok, err := s.openAttention(id)
		if err != nil {
			return httpResult{503, Object{}}, nil
		}
		if !ok {
			return httpResult{409, Object{"ok": false}}, nil
		}
		return Object{"ok": true}, nil
	}
	return nil, fail(404, "unsupported")
}

func bridgeConfig() (Object, error) {
	if token := os.Getenv("CODEX_STATUS_TOKEN"); token != "" {
		return Object{"CODEX_STATUS_TOKEN": token}, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(filepath.Join(home, "Library/Application Support/ESP32CodexBridge/config.json"))
	if err != nil {
		return nil, err
	}
	var config Object
	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, err
	}
	return config, nil
}

func (s *server) bridgeRequest(address, method string, value Object) (Object, int, error) {
	config, err := bridgeConfig()
	if err != nil {
		return nil, 0, err
	}
	token, ok := config["CODEX_STATUS_TOKEN"].(string)
	if !ok || token == "" {
		return nil, 0, errors.New("未配置状态服务凭据")
	}
	var body io.Reader
	if value != nil {
		raw, err := json.Marshal(value)
		if err != nil {
			return nil, 0, err
		}
		body = bytes.NewReader(raw)
	}
	request, err := http.NewRequest(method, address, body)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("X-Codex-Status-Token", token)
	if value != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := s.client.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, response.StatusCode, errors.New("状态服务请求失败")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1000001))
	if err != nil || len(raw) > 1000000 {
		return nil, response.StatusCode, errors.New("状态服务返回无效数据")
	}
	var result Object
	if err := json.Unmarshal(raw, &result); err != nil || result == nil {
		return nil, response.StatusCode, errors.New("状态服务返回无效数据")
	}
	return result, response.StatusCode, nil
}

func (s *server) readStatus() (Object, error) {
	value, _, err := s.bridgeRequest(envDefault("STATUS_URL", "http://127.0.0.1:8787/status"), "GET", nil)
	if err != nil {
		return nil, err
	}
	if schema, ok := number(value["schema"]); !ok || schema != 1 {
		return nil, errors.New("状态数据版本不支持")
	}
	return selectFields(value, "state", "message", "plan", "primary", "secondary", "conversations", "conversationsTotal", "conversationsAvailable", "quotaAvailable", "cached", "updatedAt", "servedAt", "attention"), nil
}

func (s *server) openAttention(id string) (bool, error) {
	snapshot, err := s.readStatus()
	if err != nil {
		return false, err
	}
	allowed := false
	if tasks, ok := snapshot["conversations"].([]any); ok {
		for _, raw := range tasks {
			if task, ok := raw.(Object); ok && task["threadId"] == id {
				allowed = true
			}
		}
	}
	if attention, ok := snapshot["attention"].(Object); ok && attention["threadId"] == id {
		allowed = true
	}
	if !allowed {
		return false, nil
	}
	address := os.Getenv("STATUS_URL")
	if address == "" {
		config, err := bridgeConfig()
		if err != nil {
			return false, err
		}
		base, _ := config["url"].(string)
		if index := strings.LastIndex(base, "/"); index >= 0 {
			base = base[:index]
		}
		address = base + "/status"
	}
	if index := strings.LastIndex(address, "/"); index >= 0 {
		address = address[:index] + "/open"
	}
	value, status, err := s.bridgeRequest(address, "POST", Object{"threadId": id})
	if status == 409 {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return value["ok"] == true, nil
}
