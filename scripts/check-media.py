"""只读验证组包后的媒体组件能在当前系统加载，不控制播放器或输出媒体信息。"""
import json
from pathlib import Path
import subprocess


base = (Path(__file__).resolve().parents[1] /
        ".build/iPad 控制台.app/Contents/Resources/MediaAdapter")
result = subprocess.run(
    ["/usr/bin/perl", str(base / "mediaremote-adapter.pl"),
     str(base / "MediaRemoteAdapter.framework"), str(base / "MediaRemoteAdapterTestClient"),
     "get", "--no-artwork", "--now"],
    capture_output=True, timeout=15, check=False,
)
# 无播放器时 null 也是正常结果；加载失败或异常输出不能算作兼容性通过。
assert result.returncode == 0, "媒体组件加载或只读查询失败"
assert isinstance(json.loads(result.stdout), (dict, type(None))), "媒体查询未返回合法快照"
print("当前系统的媒体组件加载与只读查询通过")
