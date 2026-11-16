"""验证发行脚本在凭据或参数不正确时提前拒绝，不调用签名或提交公证。"""
from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def rejects(script, expected, values=None, args=()):
    env = os.environ.copy()
    for name in ("SIGNING_IDENTITY", "NOTARY_KEYCHAIN_PROFILE", "BUILD_CONFIGURATION", "APP_VERSION", "APP_BUILD"):
        env.pop(name, None)
    env.update(values or {})
    result = subprocess.run(["bash", str(ROOT / script), *args], env=env, cwd=ROOT,
                            capture_output=True, text=True, check=False, timeout=15)
    assert result.returncode != 0, f"{script} 应拒绝本次输入"
    assert expected in result.stderr, f"{script} 未返回预期的拒绝原因"


for script in ("mac_app/build.sh", "mac_app/release.sh"):
    subprocess.run(["bash", "-n", str(ROOT / script)], check=True)
rejects("mac_app/build.sh", "APP_VERSION", {"APP_VERSION": "0.1.0;echo unsafe"})
rejects("mac_app/build.sh", "APP_BUILD", {"APP_BUILD": "0"})
rejects("mac_app/build.sh", "BUILD_CONFIGURATION", {"BUILD_CONFIGURATION": "unknown"})
rejects("mac_app/build.sh", "Developer ID Application", {"BUILD_CONFIGURATION": "release", "SIGNING_IDENTITY": "-"})
rejects("mac_app/release.sh", "用法", args=("invalid",))
rejects("mac_app/release.sh", "不会产出未公证安装包", args=("0.1.0-beta.1",))
# 使用隔离命令夹具验证真实发行脚本，不触碰系统策略、签名或公证服务。
with tempfile.TemporaryDirectory(prefix="ipad-release-gate-") as folder:
    bin_path = Path(folder)
    for name, body in {
        "spctl": '#!/bin/sh\nprintf "%s\\n" "$TEST_GATEKEEPER_STATUS"\n',
        "git": "#!/bin/sh\nexit 1\n",
    }.items():
        path = bin_path / name
        path.write_text(body)
        path.chmod(0o700)
    values = {"PATH": folder + os.pathsep + os.environ.get("PATH", os.defpath),
              "SIGNING_IDENTITY": "fixture", "NOTARY_KEYCHAIN_PROFILE": "fixture"}
    for status in ("assessments disabled", "", "unknown"):
        rejects("mac_app/release.sh", "Gatekeeper", values | {"TEST_GATEKEEPER_STATUS": status}, ("0.1.0-beta.1",))
    rejects("mac_app/release.sh", "请先提交", values | {"TEST_GATEKEEPER_STATUS": "assessments enabled"}, ("0.1.0-beta.1",))
print("发行参数、缺凭据与 Gatekeeper 状态阻断验证通过")

# 拦截签名与编译命令，用真实构建入口验证媒体架构和最低系统的拒绝路径。
with tempfile.TemporaryDirectory(prefix="ipad-build-gate-") as folder:
    tool = Path(folder) / "xcrun"
    tool.write_text('''#!/bin/sh
case "$1" in
  lipo) printf '%s\\n' "$TEST_MEDIA_ARCH" ;;
  vtool) printf 'platform MACOS\\nminos %s\\n' "$TEST_MEDIA_MINIMUM" ;;
  *) exit 97 ;;
esac
''')
    tool.chmod(0o700)
    values = {"PATH": folder + os.pathsep + os.environ.get("PATH", os.defpath),
              "TEST_MEDIA_ARCH": "arm64", "TEST_MEDIA_MINIMUM": "27.0"}
    rejects("mac_app/build.sh", "最低系统", values)
    rejects("mac_app/build.sh", "arm64 架构", values | {"TEST_MEDIA_ARCH": "x86_64", "TEST_MEDIA_MINIMUM": "13.0"})
print("媒体架构与最低系统阻断验证通过")
