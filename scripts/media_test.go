package scripts

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestMediaValidation(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("媒体组件验证使用 macOS 原生 Swift 工具链")
	}
	xcrun, err := exec.LookPath("xcrun")
	if err != nil {
		t.Fatal(err)
	}
	_, source, _, _ := runtime.Caller(0)
	script, err := os.ReadFile(filepath.Join(filepath.Dir(source), "check-media.swift"))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, perl string
		ok         bool
	}{
		{"idle", `print "null";`, true},
		{"snapshot", `print '{"private":"PRIVATE_MEDIA_OUTPUT"}';`, true},
		{"large-pipe", `print " " x 131072; print "{}";`, true},
		{"oversized-output", `print " " x (5 * 1024 * 1024);`, false},
		{"array", `print "[]";`, false},
		{"scalar", `print "true";`, false},
		{"invalid-json", `print "not-json";`, false},
		{"nonzero-exit", `print STDERR "PRIVATE_MEDIA_OUTPUT"; exit 7;`, false},
		{"timeout", `sleep 30;`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.name == "timeout" && testing.Short() {
				t.Skip("完整运行验证真实的 15 秒超时")
			}
			root := t.TempDir()
			folder := filepath.Join(root, "scripts")
			adapter := filepath.Join(root, ".build/iPad 控制台.app/Contents/Resources/MediaAdapter")
			for _, path := range []string{folder, adapter} {
				if err := os.MkdirAll(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			path := filepath.Join(folder, "check-media.swift")
			if err := os.WriteFile(path, script, 0600); err != nil {
				t.Fatal(err)
			}
			// 夹具只返回合成数据，并检查验证器不会发出播放器控制命令。
			body := `die "unexpected arguments" unless @ARGV == 5 && $ARGV[2] eq "get" && $ARGV[3] eq "--no-artwork" && $ARGV[4] eq "--now"; ` + test.perl
			if err := os.WriteFile(filepath.Join(adapter, "mediaremote-adapter.pl"), []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, xcrun, "swift", "-module-cache-path", filepath.Join(filepath.Dir(source), "../.build/swift-cache"), path)
			output, err := command.CombinedOutput()
			if ctx.Err() != nil {
				t.Fatal("媒体验证器未在自身超时后退出")
			}
			if (err == nil) != test.ok {
				t.Fatalf("success=%v, want %v: %s", err == nil, test.ok, output)
			}
			if bytes.Contains(output, []byte("PRIVATE_MEDIA_OUTPUT")) {
				t.Fatal("媒体信息泄漏到验证日志")
			}
		})
	}
}
