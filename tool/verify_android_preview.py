"""Validate the exact arm64 AOT preview before uploading a CI artifact."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


def main():
    folder = Path('build/preview/android')
    apk = folder / 'FocuBili-v1.8.2-arm64-preview.apk'
    metadata = Path('lib/core/build_metadata.g.dart').read_text()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == os.environ['GITHUB_SHA']
    assert f'appSourceRevision = "{revision}";' in metadata
    badging = (folder / 'apk-badging.txt').read_text()
    signature = (folder / 'apk-signature.txt').read_text()
    assert "package: name='com.focubili.app.preview' versionCode='32' versionName='1.8.2-preview'" in badging
    assert "sdkVersion:'24'" in badging and "targetSdkVersion:'36'" in badging
    assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature
    certificates = set(re.findall(
        r'^(?:Signer #\d+|V[\d.]+ Signer):? certificate SHA-256 digest: ([0-9a-fA-F]+)$',
        signature, re.M,
    ))
    assert len(certificates) == 1
    certificate = certificates.pop().upper()
    assert certificate == os.environ['ANDROID_RELEASE_CERT_SHA256']
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({name.split('/')[1] for name in archive.namelist()
                       if name.startswith('lib/') and name.endswith('.so')})
        assert abis == ['arm64-v8a']
        assert not any(name.endswith('kernel_blob.bin') for name in archive.namelist())
        binary = archive.read('lib/arm64-v8a/libapp.so')
        assert binary.startswith(b'\x7fELF')
        assert any(revision.encode(encoding) in binary for encoding in ('utf-8', 'utf-16le'))
    assert apk.stat().st_size < 25 * 1024 * 1024
    mapping = Path('build/app/outputs/mapping/release/mapping.txt')
    assert mapping.is_file() and mapping.stat().st_size > 0
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    result = {
        'source_sha': revision, 'version': '1.8.2+32', 'file': apk.name,
        'bytes': apk.stat().st_size, 'sha256': digest,
        'package': 'com.focubili.app.preview', 'versionName': '1.8.2-preview',
        'versionCode': 32, 'architectures': abis, 'mode': 'Release/AOT',
        'r8': True, 'resource_shrinking': True,
        'certificateSha256': certificate.lower(), 'signature_verified': True,
        'signing': 'Existing repository Android signing configuration; no new credential',
        'compatibility': 'Separate from stable com.focubili.app; cannot replace a differently signed debug preview or a preview with versionCode greater than 32',
        'device_playback_tested': False,
    }
    (folder / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    (folder / 'SHA256SUMS.txt').write_text(digest + '  ' + apk.name + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
