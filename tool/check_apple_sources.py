from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1]
a = root / 'packages/focubili_apple/ios/Classes/FocuBiliApplePlugin.swift'
b = root / 'packages/focubili_apple/macos/Classes/FocuBiliApplePlugin.swift'
assert a.read_bytes() == b.read_bytes(), 'Apple bridge copies have drifted'
for p in a.parent.glob('*.swift'):
    assert p.read_bytes() == (b.parent / p.name).read_bytes(), p.name
for p in [root/'ios/Runner/Info.plist', root/'macos/Runner/Info.plist', root/'macos/Runner/Release.entitlements']:
    plistlib.loads(p.read_bytes())
assert 'audio' in plistlib.loads((root/'ios/Runner/Info.plist').read_bytes())['UIBackgroundModes']
for name in ('DebugProfile.entitlements', 'Release.entitlements'):
    entitlements = plistlib.loads((root / 'macos/Runner' / name).read_bytes())
    assert entitlements.get('com.apple.security.files.user-selected.read-write') is True, name
    assert entitlements.get('com.apple.security.files.bookmarks.app-scope') is True, name
print('Apple source/metadata checks passed')
