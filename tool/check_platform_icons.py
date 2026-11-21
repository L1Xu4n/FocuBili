"""Validate authored launcher-resource coverage without Android or Xcode tools."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
res = root / 'android/app/src/main/res'
ns = '{http://schemas.android.com/apk/res/android}'
densities = dict(mdpi=(48, 108), hdpi=(72, 162), xhdpi=(96, 216),
                 xxhdpi=(144, 324), xxxhdpi=(192, 432))
manifest = ET.parse(res.parent / 'AndroidManifest.xml').getroot()
app = manifest.find('application')
assert app.attrib[ns + 'icon'] == '@mipmap/ic_launcher'
assert app.attrib[ns + 'roundIcon'] == '@mipmap/ic_launcher_round'


def png(path, size):
    data = path.read_bytes()
    assert data[:16] == b'\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR', path
    assert int.from_bytes(data[16:20], 'big') == size, path
    assert int.from_bytes(data[20:24], 'big') == size, path
    return data


for density, (legacy_size, foreground_size) in densities.items():
    day_dir = res / f'mipmap-{density}'
    night_dir = res / f'mipmap-night-{density}'
    for name in ['ic_launcher', 'ic_launcher_round']:
        assert png(day_dir / f'{name}.png', legacy_size) != png(
            night_dir / f'{name}.png', legacy_size)
    # The adaptive icon's child IDs must not independently change UI mode.
    day_name = 'ic_launcher_foreground.png'
    night_name = 'ic_launcher_foreground_dark.png'
    assert png(day_dir / day_name, foreground_size) != png(
        day_dir / night_name, foreground_size)
    assert not (night_dir / day_name).exists()
    assert not (night_dir / night_name).exists()


for resource in res.glob('mipmap-*night*/*'):
    assert resource.stem not in {'ic_launcher_foreground', 'ic_launcher_foreground_dark'}, resource

mono_layer = ET.parse(res / 'drawable/ic_launcher_monochrome.xml').getroot()
assert mono_layer.attrib[ns + 'src'] == '@mipmap/ic_launcher_foreground'


def colors(directory):
    return {
        color.attrib['name']: color.text
        for color in ET.parse(res / directory / 'colors.xml').getroot().findall('color')
    }


base_colors = colors('values')
night_colors = colors('values-night')
for mode, color in [('light', '#E3EEFC'), ('dark', '#101827')]:
    name = f'launcher_icon_bg_{mode}'
    assert base_colors[name] == color
    for path in res.glob('values-*/colors.xml'):
        assert name not in colors(path.parent.name), path
# Splash colors still follow the effective application mode.
assert base_colors['icon_bg'] == '@color/launcher_icon_bg_light'
assert night_colors['icon_bg'] == '@color/launcher_icon_bg_dark'
for name in ['ic_launcher', 'ic_launcher_round']:
    for night, mode, suffix in [('', 'light', ''), ('night-', 'dark', '_dark')]:
        for version in [26, 33]:
            path = res / f'mipmap-{night}anydpi-v{version}' / f'{name}.xml'
            icon = ET.parse(path).getroot()
            assert icon.tag == 'adaptive-icon', path
            assert icon.find('background').attrib[ns + 'drawable'] == (
                f'@color/launcher_icon_bg_{mode}'), path
            assert icon.find('foreground').attrib[ns + 'drawable'] == (
                f'@mipmap/ic_launcher_foreground{suffix}'), path
            mono = icon.find('monochrome')
            if version == 33:
                assert mono.attrib[ns + 'drawable'] == '@drawable/ic_launcher_monochrome', path
            else:
                assert mono is None, path
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
