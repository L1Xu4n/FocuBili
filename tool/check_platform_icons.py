"""Validate authored launcher-resource coverage without Android or Xcode tools."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
res = root / 'android/app/src/main/res'
ns = '{http://schemas.android.com/apk/res/android}'
for density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']:
    for night in ['', 'night-']:
        for name in ['ic_launcher', 'ic_launcher_round', 'ic_launcher_foreground']:
            assert (res / f'mipmap-{night}{density}' / f'{name}.png').is_file()
for name in ['ic_launcher', 'ic_launcher_round']:
    icon = ET.parse(res / 'mipmap-anydpi-v33' / f'{name}.xml').getroot()
    assert icon.find('monochrome').attrib[ns + 'drawable'] == '@drawable/ic_launcher_monochrome'
assert ET.parse(res / 'values-night/colors.xml').getroot().find('color').text == '#101827'
appicon = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
images = json.loads((appicon / 'Contents.json').read_text())['images']
assert any(i.get('appearances') == [{'appearance': 'luminosity', 'value': 'dark'}] for i in images)
for image in images:
    assert (appicon / image['filename']).is_file()
print('Android density/night/monochrome and iOS dark icon resources passed')
composer = root / 'macos/Runner/FocuBiliIcon.icon'
config = json.loads((composer / 'icon.json').read_text())
variants = config['groups'][0]['layers'][0]['image-name-specializations']
assert any(v.get('appearance') == 'dark' for v in variants)
for variant in variants:
    assert (composer / 'Assets' / variant['value']).is_file()
project = (root / 'macos/Runner.xcodeproj/project.pbxproj').read_text()
assert project.count('ASSETCATALOG_COMPILER_APPICON_NAME = FocuBiliIcon;') == 3
assert 'folder.iconcomposer.icon' in project
print('macOS Icon Composer light/dark sources and target references passed')
