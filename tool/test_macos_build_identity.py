import json
import unittest
from macos_build_identity import read_identity, verify_bundle_identity


class BuildIdentityTest(unittest.TestCase):
    source = 'a' * 40

    def metadata(self, **changes):
        values = dict(appSourceRevision=self.source, appFallbackVersion='1.8.0+27',
                      appBuildTime='2026-10-18T12:00:00.000Z')
        values.update(changes)
        return '\n'.join(f'const String {name} = {json.dumps(value)};' for name, value in values.items())

    def test_identity_matches_dart(self):
        identity = read_identity(self.metadata(), self.source, '1.8.0+27')
        verify_bundle_identity(identity, identity)

    def test_source_version_time_and_bundle_mismatches_reject(self):
        for changes in [dict(appSourceRevision='b' * 40),
                        dict(appFallbackVersion='1.8.0+26'),
                        dict(appBuildTime='local-development'),
                        dict(appBuildTime='2026-10-18T12:00:00+08:00')]:
            with self.subTest(changes=changes), self.assertRaises((AssertionError, ValueError)):
                read_identity(self.metadata(**changes), self.source, '1.8.0+27')
        identity = read_identity(self.metadata(), self.source, '1.8.0+27')
        for key in identity:
            info = dict(identity)
            info[key] = 'incorrect'
            with self.subTest(key=key), self.assertRaises(AssertionError):
                verify_bundle_identity(info, identity)


if __name__ == '__main__':
    unittest.main()
