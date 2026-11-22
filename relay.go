package main

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

type usageCache struct {
	url    string
	key    string
	at     time.Time
	result Object
}

type Relay struct {
	mu      sync.Mutex
	dataDir string
	cache   map[string]usageCache
	client  *http.Client
}

func NewRelay(dataDir string) *Relay {
	return &Relay{dataDir: dataDir, cache: make(map[string]usageCache), client: &http.Client{
		Timeout: 12 * time.Second,
		// 认证头只发给已配置站点，不随重定向转交其他地址。
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (r *Relay) readKeysLocked() ([]Object, error) {
	data, err := os.ReadFile(filepath.Join(r.dataDir, "keys.json"))
	if os.IsNotExist(err) {
		return []Object{}, nil
	}
	if err != nil {
		return nil, err
	}
	var keys []Object
	if json.Unmarshal(data, &keys) != nil || keys == nil {
		return nil, fail(400, "invalid_request")
	}
	for _, item := range keys {
		for _, field := range []string{"id", "name", "key"} {
			if _, ok := item[field].(string); !ok {
				return nil, fail(400, "invalid_request")
			}
		}
	}
	return keys, nil
}

func (r *Relay) PublicKeys() (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	keys, err := r.readKeysLocked()
	if err != nil {
		return nil, err
	}
	result := make([]Object, 0, len(keys))
	for _, item := range keys {
		key := item["key"].(string)
		masked := "****"
		// 短 Key 不展示首尾，避免掩码两端拼回完整凭据。
		if len(key) > 6 {
			masked = key[:2] + "****" + key[len(key)-4:]
		}
		result = append(result, Object{"id": item["id"], "name": item["name"], "maskedKey": masked})
	}
	return result, nil
}

func (r *Relay) ChangeKey(value Object) (Object, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	keys, err := r.readKeysLocked()
	if err != nil {
		return nil, err
	}
	id := ""
	if raw, exists := value["id"]; exists && raw != nil {
		var ok bool
		id, ok = raw.(string)
		if !ok {
			return nil, fail(400, "invalid_request")
		}
	}
	index := -1
	for i, item := range keys {
		if item["id"] == id {
			index = i
			break
		}
	}
	if id != "" && index < 0 {
		return nil, fail(400, "invalid_request")
	}
	switch value["action"] {
	case "delete":
		if index < 0 {
			return nil, fail(400, "invalid_request")
		}
		keys = append(keys[:index], keys[index+1:]...)
	case "save":
		name, ok := value["name"].(string)
		name = strings.TrimSpace(name)
		if !ok || name == "" || utf8.RuneCountInString(name) > 60 {
			return nil, fail(400, "invalid_request")
		}
		key := ""
		if raw, exists := value["key"]; exists {
			key, ok = raw.(string)
			if !ok {
				return nil, fail(400, "invalid_request")
			}
		}
		if len(key) > 512 {
			return nil, fail(400, "invalid_request")
		}
		for _, c := range key {
			if c < 33 || c >= 127 {
				return nil, fail(400, "invalid_request")
			}
		}
		if index < 0 {
			if key == "" || len(keys) >= 50 {
				return nil, fail(400, "invalid_request")
			}
			keys = append(keys, Object{"id": newID(), "key": key})
			index = len(keys) - 1
		}
		keys[index]["name"] = name
		if key != "" {
			keys[index]["key"] = key
		}
	default:
		return nil, fail(400, "invalid_request")
	}
	if err := os.MkdirAll(r.dataDir, 0700); err != nil {
		return nil, err
	}
	// 同目录临时文件默认 0600，写完落盘再替换，避免中断损坏旧配置。
	file, err := os.CreateTemp(r.dataDir, ".keys-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	if err = json.NewEncoder(file).Encode(keys); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if err := os.Rename(file.Name(), filepath.Join(r.dataDir, "keys.json")); err != nil {
		return nil, err
	}
	delete(r.cache, id)
	return Object{"ok": true}, nil
}

func (r *Relay) usageURLLocked() (string, error) {
	data, err := os.ReadFile(filepath.Join(r.dataDir, "station.json"))
	if os.IsNotExist(err) {
		return "", fail(400, "invalid_request")
	}
	if err != nil {
		return "", err
	}
	var station Object
	if json.Unmarshal(data, &station) != nil || station == nil || station["type"] != "sub2api" {
		return "", fail(400, "invalid_request")
	}
	address, ok := station["url"].(string)
	if !ok {
		return "", fail(400, "invalid_request")
	}
	address = strings.TrimRight(strings.TrimSpace(address), "/")
	for _, c := range address {
		if c == '\\' || c < 32 || unicode.IsSpace(c) {
			return "", fail(400, "invalid_request")
		}
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.EscapedPath() != "" && parsed.EscapedPath() != "/v1") {
		return "", fail(400, "invalid_request")
	}
	if port := parsed.Port(); port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return "", fail(400, "invalid_request")
		}
	}
	parsed.Path, parsed.RawPath = "/v1/usage", ""
	return parsed.String(), nil
}

func usageNumber(value any) any {
	n, ok := number(value)
	if !ok || math.IsNaN(n) || math.IsInf(n, 0) || math.Abs(n) >= 1e15 {
		return nil
	}
	return n
}

func (r *Relay) fetchUsage(address, key string) Object {
	failed := func(message string) Object {
		return Object{"error": message, "updatedAt": float64(time.Now().UnixNano()) / 1e9}
	}
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return failed("查询失败，请检查 Key 或稍后重试")
	}
	request.Header.Set("Authorization", "Bearer "+key)
	response, err := r.client.Do(request)
	if err != nil {
		return failed("查询失败，请检查 Key 或稍后重试")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if response.StatusCode == 401 || response.StatusCode == 403 {
			return failed("Key 无效或无权访问")
		}
		return failed("中转站暂时不可用")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1_000_001))
	if err != nil || len(raw) > 1_000_000 {
		return failed("查询失败，请检查 Key 或稍后重试")
	}
	var data Object
	if json.Unmarshal(raw, &data) != nil || data == nil || data["isValid"] != true {
		return failed("查询失败，请检查 Key 或稍后重试")
	}
	subscription := Object{}
	if raw := data["subscription"]; raw != nil {
		var ok bool
		subscription, ok = raw.(map[string]any)
		if !ok {
			return failed("查询失败，请检查 Key 或稍后重试")
		}
	}
	unit, _ := data["unit"].(string)
	if unit != "USD" && unit != "CNY" {
		unit = ""
	}
	// 只输出额度展示字段，不透传上游凭据，也不混用不同统计口径。
	return Object{"remaining": usageNumber(data["remaining"]), "unit": unit, "dailyLimit": usageNumber(subscription["daily_limit_usd"]),
		"dailyUsed": usageNumber(subscription["daily_usage_usd"]), "updatedAt": float64(time.Now().UnixNano()) / 1e9}
}

func (r *Relay) ReadUsage(id string, force bool) (Object, error) {
	r.mu.Lock()
	keys, err := r.readKeysLocked()
	if err != nil {
		r.mu.Unlock()
		return nil, err
	}
	key, found := "", false
	for _, item := range keys {
		if item["id"] == id {
			key, found = item["key"].(string), true
			break
		}
	}
	if !found {
		r.mu.Unlock()
		return nil, fail(400, "invalid_request")
	}
	address, err := r.usageURLLocked()
	if err != nil {
		r.mu.Unlock()
		return nil, err
	}
	if cached, ok := r.cache[id]; !force && ok && cached.url == address && cached.key == key && time.Since(cached.at) < 60*time.Second {
		r.mu.Unlock()
		return clone(cached.result), nil
	}
	r.mu.Unlock()
	result := r.fetchUsage(address, key)
	r.mu.Lock()
	defer r.mu.Unlock()
	keys, err = r.readKeysLocked()
	if err != nil {
		return nil, err
	}
	currentAddress, err := r.usageURLLocked()
	if err != nil {
		return nil, err
	}
	// 换钥、删除或切换站点后，旧请求的回包不能写入新配置的缓存。
	for _, item := range keys {
		if item["id"] == id && item["key"] == key && currentAddress == address {
			r.cache[id] = usageCache{url: address, key: key, at: time.Now(), result: result}
			return clone(result), nil
		}
	}
	return nil, fail(400, "invalid_request")
}
