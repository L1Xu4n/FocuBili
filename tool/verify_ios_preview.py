"""Validate an unsigned release iPhoneOS IPA before uploading it to Actions."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import zipfile


def require_device_platform(info, build_info):
    assert info['CFBundleIdentifier'] == 'com.focubili.app'
    assert info['CFBundleShortVersionString'] == '1.8.2'
    assert info['CFBundleVersion'] == '32'
    assert info['DTPlatformName'] == 'iphoneos'
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert 2 in info['UIDeviceFamily'], 'App must support iPad'
    platforms = re.findall(r'^\s*platform\s+(\S+)\s*$', build_info, re.M)
    assert platforms == ['IOS'], f'Expected device Mach-O, got {platforms}'


def arm64_macho_slice(binary):
    """Flutter can wrap a single arm64 Mach-O in a fat container."""
    magic = binary[:4]
    fat = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
           b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
    if magic in fat:
        endian, wide = fat[magic]
        assert len(binary) >= 8
        count, = struct.unpack_from(endian + 'I', binary, 4)
        assert count == 1, 'Expected only one device arm64 slice'
        header_size = 8 + (32 if wide else 20)
        assert len(binary) >= header_size
        if wide:
            cpu, subtype, offset, size, alignment, reserved = struct.unpack_from(endian + 'IIQQII', binary, 8)
        else:
            cpu, subtype, offset, size, alignment = struct.unpack_from(endian + 'IIIII', binary, 8)
        assert cpu == 0x0100000C, 'Expected arm64 CPU type'
        assert offset >= header_size and size >= 32 and offset + size <= len(binary)
        binary = binary[offset:offset + size]
        magic = binary[:4]
    assert magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'), 'Expected Mach-O 64'
    assert len(binary) >= 32
    endian = '<' if magic == b'\xcf\xfa\xed\xfe' else '>'
    cpu, = struct.unpack_from(endian + 'I', binary, 4)
    assert cpu == 0x0100000C, 'Expected arm64 CPU type'
    return binary


def require_aot_source(binary, revision):
    assert re.fullmatch(r'[0-9a-f]{40}', revision)
    binary = arm64_macho_slice(binary)
    for value in (revision, 'playback_preferences.ios_decode_mode',
                  'playback_preferences.ios_video_codec', 'hwdec-current'):
        assert any(value.encode(encoding) in binary for encoding in ('utf-8', 'utf-16le')), value


def require_unsigned_or_adhoc(returncode, details):
    if returncode == 0:
        assert 'Signature=adhoc' in details
        assert not re.search(r'^Authority=', details, re.M)
        assert not re.search(r'^TeamIdentifier=(?!not set$).+', details, re.M)
        return 'ad-hoc-only; no Apple signing identity or provisioning'
    assert 'not signed at all' in details, 'Could not determine signing state'
    return 'unsigned; no Apple signing identity or provisioning'


def main():
    folder = Path('build/preview/ios')
    ipa = folder / 'FocuBili-v1.8.2-ios-unsigned-preview.ipa'
    app = Path('build/ios/iphoneos/Runner.app')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == os.environ['GITHUB_SHA']
    metadata = Path('lib/core/build_metadata.g.dart').read_text()
    assert f'appSourceRevision = "{revision}";' in metadata
    assert 'appFallbackVersion = "1.8.2+32";' in metadata
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    build_info = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(executable)], text=True)
    require_device_platform(info, build_info)
    (folder / 'device-build-info.txt').write_text(build_info)
    binaries = [executable, app / 'Frameworks/App.framework/App', app / 'Frameworks/Flutter.framework/Flutter']
    for binary in binaries:
        archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
        assert archs == ['arm64'], (binary.name, archs)
    aot = binaries[1].read_bytes()
    require_aot_source(aot, revision)
    assert not list(app.rglob('kernel_blob.bin')), 'Debug kernel payload is not a release preview'
    assert not (app / 'embedded.mobileprovision').exists()
    signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    signing_state = require_unsigned_or_adhoc(signing.returncode, signing.stdout)
    (folder / 'signature-status.txt').write_text(signing.stdout)
    with zipfile.ZipFile(ipa) as archive:
        assert archive.testzip() is None
        prefix = 'Payload/Runner.app/'
        assert plistlib.loads(archive.read(prefix + 'Info.plist')) == info
        assert archive.read(prefix + 'Frameworks/App.framework/App') == aot
        assert archive.read(prefix + info['CFBundleExecutable']) == executable.read_bytes()
        assert not any(name.endswith('embedded.mobileprovision') for name in archive.namelist())
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    result = {
        'source_sha': revision, 'version': '1.8.2+32', 'file': ipa.name,
        'bytes': ipa.stat().st_size, 'sha256': digest,
        'bundle_identifier': info['CFBundleIdentifier'],
        'architectures': ['arm64'], 'platform': 'iPhoneOS device',
        'minimum_os': info['MinimumOSVersion'], 'mode': 'Release/AOT',
        'signing': signing_state, 'installable_without_resigning': False,
        'provisioning_profile_embedded': False,
        'decode_settings_in_aot_verified': True,
        'device_playback_tested': False, 'thermal_improvement_tested': False,
    }
    (folder / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    (folder / 'SHA256SUMS.txt').write_text(digest + '  ' + ipa.name + '\n')
    (folder / 'build_metadata.g.dart').write_text(metadata)
    (folder / 'INSTALL.txt').write_text(
        'Unsigned/ad-hoc-only iPhoneOS arm64 developer preview, version 1.8.2+32.\n'
        'Requires your own Apple signing and provisioning before installing on iPad/iPhone.\n'
        'Not an App Store/TestFlight package and not a simulator build.\n'
        'Bundle identifier: com.focubili.app. Re-signing tool/account rules determine whether it can replace an existing installation.\n'
        'Native compilation and embedded source/settings were verified, not real-device playback or heat reduction.\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
