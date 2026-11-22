package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
)

type Object = map[string]any

type apiError struct {
	Status  int
	Message string
}

func (e *apiError) Error() string           { return e.Message }
func fail(status int, message string) error { return &apiError{status, message} }

func digest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

var identityPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var credentialPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43,128}$`)

func validID(value any) (string, error) {
	text, ok := value.(string)
	if !ok || !identityPattern.MatchString(text) {
		return "", fail(400, "invalid_identity")
	}
	return text, nil
}

func credential(value any) (string, error) {
	text, ok := value.(string)
	if !ok || !credentialPattern.MatchString(text) {
		return "", fail(401, "unauthorized")
	}
	return digest(text), nil
}

func newID() string {
	var value [16]byte
	// 系统随机源失效时必须停止生成身份，不能降级为可预测的凭据。
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[:4], value[4:6], value[6:8], value[8:10], value[10:])
}

func randomToken() string {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(value[:])
}

func number(value any) (float64, bool) {
	var result float64
	switch value := value.(type) {
	case float64:
		result = value
	case float32:
		result = float64(value)
	case int:
		result = float64(value)
	case int64:
		result = float64(value)
	case json.Number:
		var err error
		result, err = value.Float64()
		if err != nil {
			return 0, false
		}
	default:
		return 0, false
	}
	return result, !math.IsNaN(result) && !math.IsInf(result, 0)
}

func clone(value Object) Object {
	result := make(Object, len(value))
	for key, value := range value {
		result[key] = value
	}
	return result
}
