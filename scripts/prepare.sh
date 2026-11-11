#!/bin/bash
# Air Alternate 源码状态校验（只读，不修改任何文件）
#
# 旧版 prepare.sh 会在构建时用 plutil / sed / git apply 把上游源码改造成
# Air Alternate。方案 A 之后这些改动已全部固化进本仓库源码，构建流程不再
# 做任何代码变换；本脚本仅用于在本地或 CI 中快速确认源码没有被回退。
#
# 用法: bash scripts/prepare.sh [仓库根目录，默认当前目录]
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

echo "===== Air Alternate source state ====="
test -f Makefile                                      || { echo "::error::Makefile missing"; exit 1; }
test -f Natives/Info.plist                            || { echo "::error::Natives/Info.plist missing"; exit 1; }
test -f Natives/resources/Frameworks/libMoltenVK.dylib || { echo "::error::libMoltenVK.dylib missing"; exit 1; }

# 包名 / 显示名（macOS 用 plutil，其它平台用 python plistlib）
if command -v plutil >/dev/null 2>&1; then
  BID=$(plutil -extract CFBundleIdentifier raw Natives/Info.plist)
  NAME=$(plutil -extract CFBundleDisplayName raw Natives/Info.plist)
else
  BID=$(python3 -c 'import plistlib;print(plistlib.load(open("Natives/Info.plist","rb"))["CFBundleIdentifier"])')
  NAME=$(python3 -c 'import plistlib;print(plistlib.load(open("Natives/Info.plist","rb"))["CFBundleDisplayName"])')
fi
echo "bundle id    : $BID"
echo "display name : $NAME"
[ "$BID"  = "com.airalternate.amethyst" ] || { echo "::error::bundle id not baked into source"; exit 1; }
[ "$NAME" = "Air Alternate" ]             || { echo "::error::display name not baked into source"; exit 1; }

python3 - <<'PY'
import pathlib, sys
checks = [
    ('Natives/resources/Frameworks/libMoltenVK.dylib', None),
    ('Natives/LauncherPreferences.m', '@"key": @ RENDERER_NAME_MITHRIL'),
    ('Natives/shaderc_sandbox.h', 'int auto_bind_uniforms;'),
    ('Natives/DownloadViewController.m', 'AMEFetchVersionManifest'),
    ('Natives/external/ZeroTierFramework/ios-example-app/zt.framework/zt', None),
]
for path, needle in checks:
    p = pathlib.Path(path)
    if not p.is_file():
        sys.exit(f'::error::missing {path}')
    if needle and needle not in p.read_text(errors='replace'):
        sys.exit(f'::error::{path} is missing {needle!r}')
d = pathlib.Path('Natives/resources/Frameworks/libMoltenVK.dylib').read_bytes()
if len(d) < 1000000 or d[:4] != b'\xcf\xfa\xed\xfe':
    sys.exit('::error::libMoltenVK.dylib is not a real 64-bit Mach-O binary')
if b'1.4.2' not in d or b'1.2.9' in d:
    sys.exit('::error::MoltenVK is not iOS 1.4.2')
print('moltenvk     : iOS 1.4.2 (%d bytes, Mach-O arm64)' % len(d))
print('mithril      : ENABLED')
print('task55       : shaderc auto-binding fix present')
print('version page : mirror/cache fix present')
PY

if grep -q 'Amethyst-iOS-MyRemastered.git' .github/workflows/build.yml 2>/dev/null; then
  echo "::error::build.yml still clones upstream"; exit 1
fi
echo "build.yml    : checkout self (no upstream clone)"
echo "===== ALL CHECKS PASSED ====="
