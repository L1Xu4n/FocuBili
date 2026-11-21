import unittest

from stable_package_metadata import stable_identity


class StableIdentityTest(unittest.TestCase):
    def test_stable_version_is_not_a_beta_debian_version(self):
        expected = {
            "sourceSha": "f" * 40,
            "baseVersion": "1.9.0",
            "buildNumber": 32,
            "debVersion": "1.9.0",
        }
        self.assertEqual(stable_identity("name: focubili\nversion: 1.9.0+32\n", "f" * 40), expected)

    def test_rejects_beta_ambiguous_overflow_and_noncommit(self):
        for pubspec in (
            "version: 1.9.0-beta.12+2037",
            "version: 1.9.0+32\nversion: 1.9.0+2039",
            "version: 1.9.0+65536",
        ):
            with self.subTest(pubspec=pubspec), self.assertRaises(ValueError):
                stable_identity(pubspec, "f" * 40)
        with self.assertRaises(ValueError):
            stable_identity("version: 1.9.0+32", "master")


if __name__ == '__main__':
    unittest.main()
