"""验证发行脚本在凭据或参数不正确时提前拒绝，不调用签名或提交公证。"""
from pathlib import Path
import os
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def rejects(script, expected, values=None, args=()):
    env = os.environ.copy()
    for name in ("SIGNING_IDENTITY", "NOTARY_KEYCHAIN_PROFILE", "BUILD_CONFIGURATION", "APP_VERSION", "APP_BUILD"):
        env.pop(name, None)
    env.update(values or {})
    result = subprocess.run(["bash", str(ROOT / script), *args], env=env, cwd=ROOT,
                            capture_output=True, text=True, check=False)
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
print("发行参数校验和缺凭据阻断验证通过")
