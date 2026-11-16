"""验证发行脚本在凭据或参数不正确时提前拒绝，不调用签名或提交公证。"""
from pathlib import Path
import os
import shutil
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


for script in ("mac_app/build.sh", "mac_app/release.sh", "mac_app/package-preview.sh", "mac_app/package-dmg.sh", "mac_app/check-development-signature.sh"):
    subprocess.run(["bash", "-n", str(ROOT / script)], check=True)
rejects("mac_app/build.sh", "APP_VERSION", {"APP_VERSION": "0.1.0;echo unsafe"})
rejects("mac_app/build.sh", "APP_BUILD", {"APP_BUILD": "0"})
rejects("mac_app/build.sh", "BUILD_CONFIGURATION", {"BUILD_CONFIGURATION": "unknown"})
rejects("mac_app/build.sh", "Developer ID Application", {"BUILD_CONFIGURATION": "release", "SIGNING_IDENTITY": "-"})
rejects("mac_app/release.sh", "用法", args=("invalid",))
rejects("mac_app/release.sh", "不会产出未公证安装包", args=("0.1.0-beta.1",))
rejects("mac_app/package-dmg.sh", "用法")
rejects("mac_app/package-dmg.sh", "用法", args=("missing.app", "output.dmg"))
rejects("mac_app/check-development-signature.sh", "用法", args=("missing.app", "-"))
# 已有产物及符号链接一律不能覆盖，校验必须先于签名与挂载操作。
with tempfile.TemporaryDirectory(prefix="ipad-dmg-gate-") as folder:
    source = Path(folder) / "iPad 控制台.app"
    source.mkdir()
    output = Path(folder) / "existing.dmg"
    output.write_bytes(b"fixture")
    rejects("mac_app/package-dmg.sh", "拒绝覆盖", args=(str(source), str(output)))
    output.unlink()
    output.symlink_to(Path(folder) / "missing-target")
    rejects("mac_app/package-dmg.sh", "拒绝覆盖", args=(str(source), str(output)))
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

for version in ("invalid", "0.1.0", "0.1.0;echo unsafe"):
    rejects("mac_app/package-preview.sh", "只接受预发布版本", args=(version,))
# Git 夹具只允许测试执行到打包之前，不能意外触发构建或修改已安装 App。
with tempfile.TemporaryDirectory(prefix="ipad-preview-gate-") as folder:
    git = Path(folder) / "git"
    git.write_text('''#!/bin/sh
case "$1" in
  diff) test "$TEST_GIT_DIRTY" != 1 ;;
  ls-files) exit 0 ;;
  tag) printf '%s\\n' 'v0.1.0-other' ;;
  *) exit 97 ;;
esac
''')
    git.chmod(0o700)
    values = {"PATH": folder + os.pathsep + os.environ.get("PATH", os.defpath)}
    rejects("mac_app/package-preview.sh", "请先提交", values | {"TEST_GIT_DIRTY": "1"}, ("0.1.0-beta.3",))
    rejects("mac_app/package-preview.sh", "缺少对应版本标签", values | {"TEST_GIT_DIRTY": "0"}, ("0.1.0-beta.3",))
print("未公证测试版的版本、干净源码与标签保护验证通过")

# 真实 Git 夹具覆盖忽略文件泄漏：工作区看起来干净，也不能打包资源中的私密配置。
with tempfile.TemporaryDirectory(prefix="ipad-preview-private-") as folder:
    repository = Path(folder)
    (repository / "mac_app").mkdir()
    (repository / "web").mkdir()
    shutil.copy(ROOT / "mac_app/package-preview.sh", repository / "mac_app/package-preview.sh")
    (repository / ".gitignore").write_text(".env\n")
    for args in (("init", "-q"), ("add", "."),
                 ("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "fixture"),
                 ("tag", "v0.1.0-beta.3")):
        subprocess.run(["git", *args], cwd=repository, check=True, capture_output=True)
    (repository / "web/.env").write_text("TEST_ONLY=fixture\n")
    result = subprocess.run(["bash", "mac_app/package-preview.sh", "0.1.0-beta.3"],
                            cwd=repository, capture_output=True, text=True, timeout=15)
    assert result.returncode != 0 and "包括被忽略的文件" in result.stderr
    (repository / "web/.env").unlink()
    (repository / "docs").mkdir()
    for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md", "docs/UNNOTARIZED_INSTALL.md"):
        (repository / notice).write_text("fixture\n")
    subprocess.run(["git", "add", "."], cwd=repository, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "notices"], cwd=repository, check=True, capture_output=True)
    subprocess.run(["git", "tag", "v0.1.0-beta.5"], cwd=repository, check=True, capture_output=True)
    # 测试版不能再接受空身份、临时签名或同名证书，须使用唯一指纹。
    for identity in ("", "-", "Apple Development: Fixture"):
        env = os.environ.copy()
        env["SIGNING_IDENTITY"] = identity
        result = subprocess.run(["bash", "mac_app/package-preview.sh", "0.1.0-beta.5"], cwd=repository,
                                env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode != 0 and "固定 Apple Development" in result.stderr
print("资源中的 Git 忽略文件泄漏保护验证通过")
