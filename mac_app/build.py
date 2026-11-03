"""用系统 Swift 编译器打包本机 App，不引入第三方 GUI 依赖。"""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = root / '.build/iPad 控制台.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(parents=True, exist_ok=True)
iconset = root / '.build/control.iconset'
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        target = iconset / f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'
        subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                        str(root / 'web/codex-icon.png'), '--out', str(target)],
                       check=True, stdout=subprocess.DEVNULL)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(contents / 'Resources/AppIcon.icns')], check=True)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                '-module-cache-path', str(root / '.build/swift-cache'),
                '-target', 'arm64-apple-macosx13.0', str(root / 'mac_app/App.swift'),
                '-o', str(contents / 'MacOS/iPadControl')], check=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.iamxg.ipad-control', 'CFBundleName': 'iPad 控制台',
    'CFBundleDisplayName': 'iPad 控制台', 'CFBundleExecutable': 'iPadControl',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0',
    'CFBundleIconFile': 'AppIcon',
    'CFBundleVersion': '1', 'LSMinimumSystemVersion': '13.0',
    'NSHighResolutionCapable': True, 'ProjectRoot': str(root), 'PythonPath': sys.executable,
}))
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
