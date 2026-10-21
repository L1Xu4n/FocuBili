import unittest
import struct

from verify_ios_preview import arm64_macho_slice, require_aot_source, require_device_platform, require_unsigned_or_adhoc


class VerifyIosPreviewTests(unittest.TestCase):
    def test_device_platform_is_not_simulator_and_supports_ipad(self):
        info = {'CFBundleIdentifier': 'com.focubili.app',
                'CFBundleShortVersionString': '1.8.2', 'CFBundleVersion': '32',
                'DTPlatformName': 'iphoneos', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
                'UIDeviceFamily': [1, 2]}
        require_device_platform(info, '    platform IOS\n       minos 13.0\n')
        with self.assertRaises(AssertionError):
            require_device_platform(info, '    platform IOSSIMULATOR\n')
        with self.assertRaises(AssertionError):
            require_device_platform({**info, 'DTPlatformName': 'iphonesimulator'}, 'platform IOS\n')
        with self.assertRaises(AssertionError):
            require_device_platform({**info, 'UIDeviceFamily': [1]}, 'platform IOS\n')

    def test_aot_requires_exact_source_and_both_preference_keys(self):
        revision = 'a' * 40
        values = [revision, 'playback_preferences.ios_decode_mode',
                  'playback_preferences.ios_video_codec', 'hwdec-current']
        for encoding in ('utf-8', 'utf-16le'):
            header = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 0, 6, 0, 0, 0, 0)
            binary = header + b'\x00'.join(v.encode(encoding) for v in values)
            require_aot_source(binary, revision)
            with self.assertRaises(AssertionError):
                require_aot_source(binary, 'b' * 40)
            with self.assertRaises(AssertionError):
                require_aot_source(header + revision.encode(encoding), revision)

    def test_single_arm64_fat_containers_preserve_slice_validation(self):
        thin = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 0, 6, 0, 0, 0, 0) + b'AOT'
        for endian in ['>', '<']:
            for wide in [False, True]:
                magic = 0xCAFEBABF if wide else 0xCAFEBABE
                header = struct.pack(endian + 'II', magic, 1)
                arch = struct.pack(endian + ('IIQQII' if wide else 'IIIII'),
                                   0x0100000C, 0, 4096, len(thin), 12, *([0] if wide else []))
                fat = (header + arch).ljust(4096, b'\x00') + thin
                self.assertEqual(arm64_macho_slice(fat), thin)
                with self.assertRaises(AssertionError):
                    arm64_macho_slice(fat[:-1])
        with self.assertRaises(AssertionError):
            arm64_macho_slice(struct.pack('>II', 0xCAFEBABE, 2))
        with self.assertRaises(AssertionError):
            arm64_macho_slice(struct.pack('<IIIIIIII', 0xFEEDFACF, 0x01000007, 0, 6, 0, 0, 0, 0))

    def test_unsigned_and_adhoc_are_distinguished_from_provisioned_signing(self):
        self.assertIn('unsigned', require_unsigned_or_adhoc(1, 'code object is not signed at all'))
        self.assertIn('ad-hoc', require_unsigned_or_adhoc(0, 'Signature=adhoc\nTeamIdentifier=not set\n'))
        with self.assertRaises(AssertionError):
            require_unsigned_or_adhoc(0, 'Authority=Apple Development: Example\nTeamIdentifier=ABC123\n')
        with self.assertRaises(AssertionError):
            require_unsigned_or_adhoc(1, 'unrecognized bundle format')


if __name__ == '__main__':
    unittest.main()
