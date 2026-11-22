package scripts

import (
	"bytes"
	"context"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type releaseResult struct {
	stdout string
	stderr string
	err    error
}

func releaseRoot(t *testing.T) string {
	t.Helper()
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(working, "go.mod")); err == nil {
			return working
		}
		parent := filepath.Dir(working)
		if parent == working {
			t.Fatal("未找到项目根目录")
		}
		working = parent
	}
}

func writeReleaseFile(t *testing.T, path, text string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), mode); err != nil {
		t.Fatal(err)
	}
}

func copyReleaseScript(t *testing.T, root, fixture, script string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, script))
	if err != nil {
		t.Fatal(err)
	}
	writeReleaseFile(t, filepath.Join(fixture, script), string(data), 0700)
}

func releaseEnvironment(t *testing.T) map[string]string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "bin")
	// 即使前置校验发生回归，也不能触及真实签名、公证、系统策略或发布服务。
	for _, tool := range []string{"security", "codesign", "spctl", "xcrun", "hdiutil", "ditto", "rsync", "install_name_tool", "sips", "iconutil", "gh", "curl", "plutil", "python", "python3"} {
		writeReleaseFile(t, filepath.Join(bin, tool), "#!/bin/sh\nprintf '%s\\n' '测试禁止执行真实发行工具' >&2\nexit 97\n", 0700)
	}
	// 不继承宿主密钥或令牌，所有必要的测试值由调用方显式设置。
	return map[string]string{
		"PATH":                bin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"TMPDIR":              t.TempDir(),
		"LANG":                "C",
		"LC_ALL":              "C",
		"GIT_CONFIG_GLOBAL":   os.DevNull,
		"GIT_CONFIG_NOSYSTEM": "1",
	}
}

func releaseTool(t *testing.T, env map[string]string, name, body string) {
	t.Helper()
	bin := strings.Split(env["PATH"], string(os.PathListSeparator))[0]
	writeReleaseFile(t, filepath.Join(bin, name), body, 0700)
}

func runRelease(t *testing.T, cwd string, env map[string]string, timeout time.Duration, command string, args ...string) releaseResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.Dir = cwd
	cmd.WaitDelay = time.Second
	for name, value := range env {
		cmd.Env = append(cmd.Env, name+"="+value)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		t.Fatal("发行回归检查超时")
	}
	return releaseResult{stdout.String(), stderr.String(), err}
}

func redactReleaseOutput(text string, env map[string]string) string {
	for name, value := range env {
		if value != "" && (strings.Contains(name, "PRIVATE_KEY") || strings.Contains(name, "TOKEN") || strings.Contains(name, "PASSWORD")) {
			text = strings.ReplaceAll(text, value, "[已隐藏测试凭据]")
		}
	}
	return text
}

func requireReleaseFailure(t *testing.T, result releaseResult, expected string, env map[string]string) {
	t.Helper()
	if result.err == nil || !strings.Contains(result.stderr, expected) {
		t.Fatalf("应拒绝输入并包含 %q；实际错误=%v，stderr=%s", expected, result.err, redactReleaseOutput(result.stderr, env))
	}
}

func requireReleaseSuccess(t *testing.T, result releaseResult, env map[string]string) {
	t.Helper()
	if result.err != nil {
		t.Fatalf("发行夹具失败：%v；stderr=%s", result.err, redactReleaseOutput(result.stderr, env))
	}
}

func rejectReleaseScript(t *testing.T, root, script, expected string, env map[string]string, args ...string) {
	t.Helper()
	command := append([]string{filepath.Join(root, script)}, args...)
	requireReleaseFailure(t, runRelease(t, root, env, 15*time.Second, "bash", command...), expected, env)
}

func TestReleaseShellSyntax(t *testing.T) {
	root, env := releaseRoot(t), releaseEnvironment(t)
	for _, script := range []string{"build.sh", "release.sh", "package-preview.sh", "package-dmg.sh", "check-development-signature.sh", "generate-appcast.sh", "fetch-sparkle.sh"} {
		t.Run(script, func(t *testing.T) {
			requireReleaseSuccess(t, runRelease(t, root, env, 15*time.Second, "bash", "-n", filepath.Join(root, "mac_app", script)), env)
		})
	}
}

func TestReleaseInvalidArgumentsAndMissingCredentials(t *testing.T) {
	root := releaseRoot(t)
	for _, test := range []struct {
		name, script, expected string
		values                 map[string]string
		args                   []string
	}{
		{"version", "build.sh", "APP_VERSION", map[string]string{"APP_VERSION": "0.1.0;echo unsafe"}, nil},
		{"build", "build.sh", "APP_BUILD", map[string]string{"APP_BUILD": "0"}, nil},
		{"configuration", "build.sh", "BUILD_CONFIGURATION", map[string]string{"BUILD_CONFIGURATION": "unknown"}, nil},
		{"release-signature", "build.sh", "Developer ID Application", map[string]string{"BUILD_CONFIGURATION": "release", "SIGNING_IDENTITY": "-"}, nil},
		{"release-version", "release.sh", "用法", nil, []string{"invalid"}},
		{"release-credentials", "release.sh", "不会产出未公证安装包", nil, []string{"0.1.0-beta.1"}},
		{"dmg-arguments", "package-dmg.sh", "用法", nil, nil},
		{"dmg-source", "package-dmg.sh", "用法", nil, []string{"missing.app", "output.dmg"}},
		{"signature-source", "check-development-signature.sh", "用法", nil, []string{"missing.app", "-"}},
		{"appcast-arguments", "generate-appcast.sh", "用法", nil, []string{"invalid", "missing.app", "missing.zip"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			env := releaseEnvironment(t)
			for name, value := range test.values {
				env[name] = value
			}
			rejectReleaseScript(t, root, "mac_app/"+test.script, test.expected, env, test.args...)
		})
	}
}

func TestReleaseDMGExistingFileAndSymlink(t *testing.T) {
	root, fixture, env := releaseRoot(t), t.TempDir(), releaseEnvironment(t)
	source := filepath.Join(fixture, "iPad 控制台.app")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(fixture, "existing.dmg")
	writeReleaseFile(t, output, "fixture", 0600)
	rejectReleaseScript(t, root, "mac_app/package-dmg.sh", "拒绝覆盖", env, source, output)
	if err := os.Remove(output); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(fixture, "missing-target"), output); err != nil {
		t.Fatal(err)
	}
	rejectReleaseScript(t, root, "mac_app/package-dmg.sh", "拒绝覆盖", env, source, output)
}

func TestReleaseGatekeeperAndDirtyTree(t *testing.T) {
	root, env := releaseRoot(t), releaseEnvironment(t)
	releaseTool(t, env, "spctl", "#!/bin/sh\nprintf '%s\\n' \"$TEST_GATEKEEPER_STATUS\"\n")
	releaseTool(t, env, "git", "#!/bin/sh\nexit 1\n")
	env["SIGNING_IDENTITY"], env["NOTARY_KEYCHAIN_PROFILE"] = "fixture", "fixture"
	for _, status := range []string{"assessments disabled", "", "unknown"} {
		env["TEST_GATEKEEPER_STATUS"] = status
		rejectReleaseScript(t, root, "mac_app/release.sh", "Gatekeeper", env, "0.1.0-beta.1")
	}
	env["TEST_GATEKEEPER_STATUS"] = "assessments enabled"
	rejectReleaseScript(t, root, "mac_app/release.sh", "请先提交", env, "0.1.0-beta.1")
}

func TestReleaseMediaArchitectureAndMinimum(t *testing.T) {
	root, env := releaseRoot(t), releaseEnvironment(t)
	releaseTool(t, env, "xcrun", `#!/bin/sh
case "$1" in
  lipo) printf '%s\n' "$TEST_MEDIA_ARCH" ;;
  vtool) printf 'platform MACOS\nminos %s\n' "$TEST_MEDIA_MINIMUM" ;;
  *) exit 97 ;;
esac
`)
	env["TEST_MEDIA_ARCH"], env["TEST_MEDIA_MINIMUM"] = "arm64", "27.0"
	rejectReleaseScript(t, root, "mac_app/build.sh", "最低系统", env)
	env["TEST_MEDIA_ARCH"], env["TEST_MEDIA_MINIMUM"] = "x86_64", "13.0"
	rejectReleaseScript(t, root, "mac_app/build.sh", "arm64 架构", env)
}

func TestPreviewVersionDirtyTreeAndTag(t *testing.T) {
	root, env := releaseRoot(t), releaseEnvironment(t)
	for _, version := range []string{"invalid", "0.1", "0.1.0;echo unsafe"} {
		rejectReleaseScript(t, root, "mac_app/package-preview.sh", "有效版本号", env, version)
	}
	releaseTool(t, env, "git", `#!/bin/sh
case "$1" in
  diff) test "$TEST_GIT_DIRTY" != 1 ;;
  ls-files) exit 0 ;;
  tag) printf '%s\n' 'v0.1.0-other' ;;
  *) exit 97 ;;
esac
`)
	env["TEST_GIT_DIRTY"] = "1"
	rejectReleaseScript(t, root, "mac_app/package-preview.sh", "请先提交", env, "0.1.0-beta.3")
	env["TEST_GIT_DIRTY"] = "0"
	rejectReleaseScript(t, root, "mac_app/package-preview.sh", "缺少对应版本标签", env, "0.1.0-beta.3")
}

func TestPreviewIgnoredPrivateFilesAndFixedSigningIdentity(t *testing.T) {
	root, fixture, env := releaseRoot(t), t.TempDir(), releaseEnvironment(t)
	copyReleaseScript(t, root, fixture, "mac_app/package-preview.sh")
	writeReleaseFile(t, filepath.Join(fixture, ".gitignore"), ".env\n", 0600)
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=" + os.DevNull, "commit", "-qm", "fixture"}, {"tag", "v0.1.0-beta.3"}} {
		requireReleaseSuccess(t, runRelease(t, fixture, env, 15*time.Second, "git", args...), env)
	}
	private := filepath.Join(fixture, "web/.env")
	writeReleaseFile(t, private, "TEST_ONLY=fixture\n", 0600)
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", "mac_app/package-preview.sh", "0.1.0-beta.3"), "包括被忽略的文件", env)
	if err := os.Remove(private); err != nil {
		t.Fatal(err)
	}
	for _, notice := range []string{"LICENSE", "THIRD_PARTY_NOTICES.md", "docs/UNNOTARIZED_INSTALL.md"} {
		writeReleaseFile(t, filepath.Join(fixture, notice), "fixture\n", 0600)
	}
	for _, args := range [][]string{{"add", "."}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=" + os.DevNull, "commit", "-qm", "notices"}, {"tag", "v0.1.0-beta.5"}, {"tag", "v0.1.0"}} {
		requireReleaseSuccess(t, runRelease(t, fixture, env, 15*time.Second, "git", args...), env)
	}
	for _, version := range []string{"0.1.0", "0.1.0-beta.5"} {
		for _, identity := range []string{"", "-", "Apple Development: Fixture"} {
			env["SIGNING_IDENTITY"] = identity
			requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", "mac_app/package-preview.sh", version), "固定 Apple Development", env)
		}
	}
}

func TestReleaseGitHubStableAndPrereleaseOptions(t *testing.T) {
	root, fixture, env := releaseRoot(t), t.TempDir(), releaseEnvironment(t)
	workflow, err := os.ReadFile(filepath.Join(root, ".github/workflows/release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	_, step, found := strings.Cut(string(workflow), "      - name: Publish unnotarized release\n")
	if !found {
		t.Fatal("未找到真实工作流中的发布步骤")
	}
	step, _, _ = strings.Cut(step, "      - name:")
	_, script, found := strings.Cut(step, "        run: |\n")
	if !found {
		t.Fatal("发布步骤缺少 shell 脚本")
	}
	lines := strings.Split(script, "\n")
	for i := range lines {
		lines[i] = strings.TrimPrefix(lines[i], "          ")
	}
	script = strings.Join(lines, "\n")
	// 只记录本地参数，不允许夹具调用联网的 GitHub CLI。
	releaseTool(t, env, "gh", `#!/bin/sh
if [ "$1" = release ] && [ "$2" = view ]; then
  test "$TEST_RELEASE_EXISTS" = 1
  exit $?
fi
if [ "$1" = release ] && [ "$2" = upload ]; then exit 0; fi
printf '%s\n' "$@" > "$GH_ARGUMENT_LOG"
`)
	log := filepath.Join(fixture, "arguments")
	env["RUNNER_TEMP"], env["GH_ARGUMENT_LOG"] = fixture, log
	for _, version := range []string{"0.1.0", "0.2.0-beta.1"} {
		if err := os.MkdirAll(filepath.Join(fixture, ".build/previews", version), 0700); err != nil {
			t.Fatal(err)
		}
		for _, exists := range []string{"0", "1"} {
			env["RELEASE_TAG"], env["TEST_RELEASE_EXISTS"] = "v"+version, exists
			requireReleaseSuccess(t, runRelease(t, fixture, env, 15*time.Second, "bash", "-c", script), env)
			data, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			args := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
			operation := "create"
			if exists == "1" {
				operation = "edit"
			}
			if len(args) < 2 || args[0] != "release" || args[1] != operation {
				t.Fatalf("发布操作错误：%q", args)
			}
			contains := func(want string) bool {
				for _, arg := range args {
					if arg == want {
						return true
					}
				}
				return false
			}
			if strings.Contains(version, "-") {
				if !contains("--prerelease") || contains("--latest") {
					t.Fatalf("预发布参数错误：%q", args)
				}
			} else if !contains("--latest") || contains("--prerelease") || contains("--prerelease=false") != (exists == "1") {
				t.Fatalf("稳定版参数错误：%q", args)
			}
		}
	}
}

func TestSparkleCorruptCacheKeepsExistingFramework(t *testing.T) {
	root, fixture, env := releaseRoot(t), t.TempDir(), releaseEnvironment(t)
	copyReleaseScript(t, root, fixture, "mac_app/fetch-sparkle.sh")
	existing := filepath.Join(fixture, ".build/sparkle/Sparkle.framework/fixture")
	writeReleaseFile(t, existing, "existing-framework", 0600)
	writeReleaseFile(t, filepath.Join(fixture, ".build/sparkle/Sparkle-2.10.1.tar.xz"), "corrupt-cache", 0600)
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", "mac_app/fetch-sparkle.sh"), "摘要不匹配", env)
	data, err := os.ReadFile(existing)
	if err != nil || string(data) != "existing-framework" {
		t.Fatal("损坏缓存覆盖了已有 Sparkle 组件")
	}
}

func appcastFixture(t *testing.T) (string, map[string]string, []string) {
	t.Helper()
	root, fixture, env := releaseRoot(t), t.TempDir(), releaseEnvironment(t)
	copyReleaseScript(t, root, fixture, "mac_app/generate-appcast.sh")
	writeReleaseFile(t, filepath.Join(fixture, "mac_app/update-public-key.txt"), "fixture-public-key\n", 0600)
	app := filepath.Join(fixture, "fixture.app")
	if err := os.Mkdir(app, 0700); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(fixture, "update.zip")
	writeReleaseFile(t, archive, "test-only-update", 0600)
	releaseTool(t, env, "plutil", `#!/bin/sh
case "$2" in
  SUPublicEDKey) printf '%s\n' "${TEST_PUBLIC_KEY:-fixture-public-key}" ;;
  CFBundleGetInfoString) printf '%s\n' "$TEST_VERSION" ;;
  SURequireSignedFeed) printf '%s\n' "${TEST_SIGNED_FEED:-true}" ;;
  *) exit 97 ;;
esac
`)
	writeReleaseFile(t, filepath.Join(fixture, ".build/sparkle/bin/generate_keys"), "#!/bin/sh\nprintf '%s\\n' \"${TEST_KEYCHAIN_PUBLIC_KEY:-fixture-public-key}\"\n", 0700)
	writeReleaseFile(t, filepath.Join(fixture, ".build/sparkle/bin/sign_update"), "#!/bin/sh\nexit 0\n", 0700)
	// 只生成本地测试 XML，不读取钥匙串、不执行真实 Sparkle 签名。
	writeReleaseFile(t, filepath.Join(fixture, ".build/sparkle/bin/generate_appcast"), `#!/bin/sh
channel=''
prefix=''
folder=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel) channel="$2"; shift 2 ;;
    --download-url-prefix) prefix="$2"; shift 2 ;;
    --*) shift 2 ;;
    *) folder="$1"; shift ;;
  esac
done
set -- "$folder/"*.zip
archive="$1"
url="$prefix$(basename "$archive")"
length="$(wc -c < "$archive" | tr -d ' ')"
namespace=sparkle
namespace_uri='http://www.andymatuschak.org/xml-namespaces/sparkle'
missing_signature=0
empty_channel=0
case "${TEST_BAD_FEED:-}" in
  url) url='https://example.invalid/update.zip' ;;
  signature) missing_signature=1 ;;
  length) length=999999 ;;
  channel) channel=unexpected ;;
  empty-channel) channel=''; empty_channel=1 ;;
  namespace-alias) namespace=s ;;
  namespace-uri) namespace_uri='https://example.invalid/sparkle' ;;
esac
signature="$namespace:edSignature=\"fixture\""
if [ "$missing_signature" = 1 ]; then signature=''; fi
{
  if [ "${TEST_BAD_FEED:-}" = doctype ]; then printf '%s\n' '<!DOCTYPE rss SYSTEM "file:///tmp/ipad-release-test-nonexistent.dtd">'; fi
  printf '<rss xmlns:%s="%s"><channel><item>\n' "$namespace" "$namespace_uri"
  if [ -n "$channel" ] || [ "$empty_channel" = 1 ]; then printf '<%s:channel>%s</%s:channel>\n' "$namespace" "$channel" "$namespace"; fi
  printf '<enclosure url="%s" length="%s" %s/>\n' "$url" "$length" "$signature"
  if [ "${TEST_BAD_FEED:-}" = duplicate ]; then printf '</item><item><enclosure url="%s" length="%s" %s/>\n' "$url" "$length" "$signature"; fi
  printf '%s\n' '</item></channel></rss>'
} > "$folder/appcast.xml"
`, 0700)
	env["TEST_VERSION"], env["CI"] = "0.1.1", "false"
	return fixture, env, []string{"mac_app/generate-appcast.sh", "0.1.1", app, archive}
}

func TestAppcastEarlyGuards(t *testing.T) {
	fixture, env, command := appcastFixture(t)
	output := filepath.Join(fixture, "appcast.xml")
	writeReleaseFile(t, output, "existing-feed", 0600)
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "拒绝覆盖", env)
	if err := os.Remove(output); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(fixture, "missing-feed"), output); err != nil {
		t.Fatal(err)
	}
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "拒绝覆盖", env)
	if err := os.Remove(output); err != nil {
		t.Fatal(err)
	}
	env["CI"] = "true"
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "SPARKLE_PRIVATE_KEY", env)
	env["CI"] = "false"
	env["TEST_PUBLIC_KEY"] = "wrong-public-key"
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "内置更新公钥不匹配", env)
	delete(env, "TEST_PUBLIC_KEY")
	env["TEST_VERSION"] = "0.1.2"
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "版本与 App 不一致", env)
	env["TEST_VERSION"] = "0.1.1"
	env["TEST_SIGNED_FEED"] = "false"
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "必须验证更新源签名", env)
	delete(env, "TEST_SIGNED_FEED")
	env["TEST_KEYCHAIN_PUBLIC_KEY"] = "wrong-keychain-key"
	requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "钥匙串更新密钥与内置公钥不匹配", env)
}

func allowReleaseSwift(t *testing.T, env map[string]string) {
	t.Helper()
	xcrun, err := exec.LookPath("xcrun")
	if err != nil {
		t.Skip("当前系统没有 xcrun；仅跳过实际 Swift XML/CryptoKit 验证，前置安全校验仍执行")
	}
	env["TEST_REAL_XCRUN"] = xcrun
	releaseTool(t, env, "xcrun", `#!/bin/sh
if [ "$1" = swift ]; then exec "$TEST_REAL_XCRUN" "$@"; fi
printf '%s\n' '测试禁止执行非 Swift 的 xcrun 工具' >&2
exit 97
`)
}

func TestAppcastURLSignatureLengthAndChannel(t *testing.T) {
	fixture, env, command := appcastFixture(t)
	allowReleaseSwift(t, env)
	output := filepath.Join(fixture, "appcast.xml")
	for _, version := range []string{"0.1.1", "0.1.1-beta.1"} {
		command[1], env["TEST_VERSION"] = version, version
		requireReleaseSuccess(t, runRelease(t, fixture, env, 60*time.Second, "bash", command...), env)
		if info, err := os.Stat(output); err != nil || !info.Mode().IsRegular() {
			t.Fatal("未产出经过验证的 appcast.xml")
		}
		requireReleaseFailure(t, runRelease(t, fixture, env, 15*time.Second, "bash", command...), "拒绝覆盖", env)
		if err := os.Remove(output); err != nil {
			t.Fatal(err)
		}
		// XML 前缀可变，但 Sparkle 的命名空间 URI 必须保持一致。
		env["TEST_BAD_FEED"] = "namespace-alias"
		requireReleaseSuccess(t, runRelease(t, fixture, env, 60*time.Second, "bash", command...), env)
		if err := os.Remove(output); err != nil {
			t.Fatal(err)
		}
		for _, invalid := range []string{"url", "signature", "length", "channel", "duplicate", "doctype", "namespace-uri", "empty-channel"} {
			env["TEST_BAD_FEED"] = invalid
			result := runRelease(t, fixture, env, 60*time.Second, "bash", command...)
			if result.err == nil {
				t.Fatalf("错误更新源 %s 未被拒绝", invalid)
			}
			if _, err := os.Lstat(output); !os.IsNotExist(err) {
				t.Fatalf("错误更新源 %s 仍写入最终输出", invalid)
			}
		}
		delete(env, "TEST_BAD_FEED")
	}
}

func TestAppcastWrongPrivateKeyDoesNotLeak(t *testing.T) {
	fixture, env, command := appcastFixture(t)
	allowReleaseSwift(t, env)
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i)
	}
	// 固定种子只用于拒绝路径；禁止将任何宿主真实私钥带入回归检查。
	wrongSeed := base64.StdEncoding.EncodeToString(seed)
	env["CI"], env["SPARKLE_PRIVATE_KEY"] = "true", wrongSeed
	result := runRelease(t, fixture, env, 60*time.Second, "bash", command...)
	if strings.Contains(result.stdout, wrongSeed) || strings.Contains(result.stderr, wrongSeed) {
		t.Fatal("错误私钥被写入测试子进程输出")
	}
	requireReleaseFailure(t, result, "与内置公钥不匹配", env)
	if _, err := os.Lstat(filepath.Join(fixture, "appcast.xml")); !os.IsNotExist(err) {
		t.Fatal("错误私钥仍产出了更新源")
	}
}
