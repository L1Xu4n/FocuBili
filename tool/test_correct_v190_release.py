"""Exercise correction checkpoints without credentials or remote GitHub writes."""
from copy import deepcopy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import correct_v190_release as correction

HEAD = "4" * 40
NEW_TAG = "a" * 40
NOTES = "# Corrected stable details\n构建号 `32`\n"
OLD_NOTES = "# Original stable details\n构建号 `2038`\n"
DRAFT_ID = 1
A = correction.tag_ref(correction.ARCHIVE)
T = correction.tag_ref(correction.TAG)


class Interrupted(Exception):
    pass


class FakeGithub:
    def __init__(self):
        self.refs_ = {correction.MASTER: HEAD, T: correction.OLD_TAG}
        self.original = {
            "id": correction.OLD_ID, "tag_name": correction.TAG, "target_commitish": "master",
            "name": correction.TITLE, "body": OLD_NOTES, "draft": False,
            "prerelease": False, "immutable": False,
            "assets": [],
        }
        self.items = {correction.OLD_ID: self.original}
        self.actions = []
        self.latest_id = correction.OLD_ID
        self.fail_after = None
        self.corrupt = None
        self.archive_ignores_target_commitish = False
        self.rest_returns_crlf = False

    def refs(self):
        return self.refs_.copy()

    def releases(self):
        return deepcopy(list(self.items.values()))

    def release(self, release_id):
        row = deepcopy(self.items[release_id])
        if self.rest_returns_crlf:
            row["body"] = row["body"].replace("\n", "\r\n")
        return row

    def latest(self):
        return self.latest_id

    def mutate(self, action):
        self.actions.append(action)
        if len(self.actions) == self.fail_after:
            raise Interrupted(action)

    def create(self, payload):
        assert self.refs_[T] == correction.OLD_TAG
        assert payload["draft"] is True and payload["make_latest"] == "false"
        self.items[DRAFT_ID] = {"id": DRAFT_ID, "immutable": False, "assets": [], **payload}
        self.mutate("create")
        return self.release(DRAFT_ID)

    def patch(self, release_id, payload):
        if release_id == correction.OLD_ID:
            assert self.refs_[A] == self.refs_[T] == correction.OLD_TAG
            assert payload["prerelease"] is True and payload["make_latest"] == "false"
            self.latest_id = -1
            action = "archive"
            if self.archive_ignores_target_commitish:
                payload = {key: value for key, value in payload.items() if key != "target_commitish"}
        elif payload.get("draft") is True:
            assert self.refs_[T] == NEW_TAG and self.refs_[A] == correction.OLD_TAG
            assert payload["make_latest"] == "false"
            action = "retag-draft"
        else:
            assert self.items[DRAFT_ID]["tag_name"] == correction.TAG
            assert self.latest_id != correction.OLD_ID
            assert payload["draft"] is False and payload["make_latest"] == "true"
            self.latest_id = DRAFT_ID
            action = "publish"
        self.items[release_id].update(payload)
        self.mutate(action)
        return self.release(release_id)

    def upload(self, release_id, path):
        assert self.items[release_id]["draft"] and release_id == DRAFT_ID
        row = {"name": path.name, "size": path.stat().st_size, "digest": correction.digest(path),
               "id": 100 + len(self.items[release_id]["assets"]), "state": "uploaded"}
        self.items[release_id]["assets"].append(row)
        self.mutate("upload")
        return row

    def verify_bytes(self, release, asset):
        if self.corrupt == (release["tag_name"], asset["name"]):
            raise RuntimeError("Corrupt asset bytes")

    def set_tag(self, name, new, old):
        ref = correction.tag_ref(name)
        assert self.refs_.get(ref, "") == old
        if name == correction.TAG:
            assert self.original["tag_name"] == correction.ARCHIVE
        self.refs_[ref] = new
        self.mutate(name)


class CorrectionTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.packages = {}
        for name in correction.OLD_ASSETS:
            path = self.root / name
            path.write_bytes(("new package fixture " + name).encode())
            self.packages[name] = path

    def run_correction(self, gh):
        correction.correct(gh, HEAD, NEW_TAG, NOTES, OLD_NOTES, self.packages,
                           self.root / "evidence")

    def assert_corrected(self, gh):
        self.assertEqual(gh.refs_[A], correction.OLD_TAG)
        self.assertEqual(gh.refs_[T], NEW_TAG)
        self.assertEqual(gh.original["tag_name"], correction.ARCHIVE)
        self.assertIs(gh.original["prerelease"], True)
        self.assertIn(OLD_NOTES, gh.original["body"])
        self.assertIn("原安装包已由维护者移除", gh.original["body"])
        self.assertEqual(gh.original["assets"], [])
        self.assertEqual(gh.latest_id, DRAFT_ID)
        published = gh.items[DRAFT_ID]
        self.assertIs(published["draft"], False)
        self.assertEqual(published["tag_name"], correction.TAG)
        self.assertEqual(published["body"], NOTES)
        self.assertEqual(len(published["assets"]), 6)
        self.assertEqual(len(gh.items), 2)

    def test_happy_path_preserves_owner_cleared_archive_without_recreating_files(self):
        gh = FakeGithub()
        self.run_correction(gh)
        self.assert_corrected(gh)
        self.assertEqual(gh.actions, ["create"] + ["upload"] * 6 + [
            correction.ARCHIVE, "archive", correction.TAG, "retag-draft", "publish",
        ])
        self.assertTrue((self.root / "evidence" / "previous-release.json").is_file())

    def test_archive_accepts_unchanged_advisory_target_if_tag_exists(self):
        gh = FakeGithub()
        gh.archive_ignores_target_commitish = True
        self.run_correction(gh)
        self.assert_corrected(gh)
        self.assertEqual(gh.original["target_commitish"], "master")

    def test_crlf_normalization_applies_to_original_archived_draft_and_published_notes(self):
        gh = FakeGithub()
        gh.rest_returns_crlf = True
        self.run_correction(gh)
        self.assert_corrected(gh)
        gh.actions.clear()
        self.run_correction(gh)
        self.assertEqual(gh.actions, [])

    def test_resumes_after_each_remote_mutation_commits_then_errors(self):
        for checkpoint in range(1, 13):
            with self.subTest(checkpoint=checkpoint):
                gh = FakeGithub()
                gh.fail_after = checkpoint
                with self.assertRaises(Interrupted):
                    self.run_correction(gh)
                self.run_correction(gh)
                self.assert_corrected(gh)
                self.assertEqual(len(gh.actions), 12)

    def test_already_published_is_read_only(self):
        gh = FakeGithub()
        self.run_correction(gh)
        gh.actions.clear()
        self.run_correction(gh)
        self.assertEqual(gh.actions, [])

    def test_invalid_original_state_never_writes(self):
        changes = [
            lambda gh: gh.original.update(immutable=True),
            lambda gh: gh.original.update(body="Unexpected notes"),
            lambda gh: gh.original.update(id=9999),
            lambda gh: gh.original.update(target_commitish="other"),
            lambda gh: gh.original.pop("assets"),
            lambda gh: gh.refs_.update({correction.MASTER: "f" * 40}),
            lambda gh: gh.refs_.update({T: "f" * 40}),
            lambda gh: gh.refs_.update({A: "f" * 40}),
            lambda gh: gh.items.update({50: {"id": 50, "tag_name": correction.ARCHIVE}}),
            lambda gh: setattr(gh, "latest_id", 50),
        ]
        for update in changes:
            with self.subTest(update=update):
                gh = FakeGithub()
                update(gh)
                with self.assertRaises(RuntimeError):
                    self.run_correction(gh)
                self.assertEqual(gh.actions, [])

    def test_corrupt_staged_bytes_stop_before_archive(self):
        gh = FakeGithub()
        gh.corrupt = (correction.STAGE, next(iter(correction.OLD_ASSETS)))
        with self.assertRaisesRegex(RuntimeError, "Corrupt asset"):
            self.run_correction(gh)
        self.assertEqual(gh.actions, ["create"] + ["upload"] * 6)
        self.assertEqual(gh.refs_[T], correction.OLD_TAG)
        self.assertEqual(gh.original["tag_name"], correction.TAG)

    def test_any_original_assets_including_exact_old_packages_are_rejected(self):
        known = [{"name": n, "id": i, "digest": d, "size": 200,
                  "state": "uploaded"} for n, (i, d) in correction.OLD_ASSETS.items()]
        for unexpected in (known[:1], known, [{"id": 9999}]):
            with self.subTest(unexpected=unexpected):
                gh = FakeGithub()
                gh.original["assets"] = unexpected
                with self.assertRaisesRegex(RuntimeError, "must contain no assets"):
                    self.run_correction(gh)
                self.assertEqual(gh.actions, [])

    def test_late_asset_in_empty_archive_stops_without_rotating_tag(self):
        gh = FakeGithub()
        gh.fail_after = 9  # Archive PATCH landed; the canonical tag has not moved.
        with self.assertRaises(Interrupted):
            self.run_correction(gh)
        gh.original["assets"] = [{"id": 9999}]
        gh.actions.clear()
        with self.assertRaisesRegex(RuntimeError, "must contain no assets"):
            self.run_correction(gh)
        self.assertEqual(gh.actions, [])
        self.assertEqual(gh.refs_[T], correction.OLD_TAG)
        self.assertEqual(gh.refs_[A], correction.OLD_TAG)

    def test_unexpected_partial_draft_stops_without_clobber(self):
        gh = FakeGithub()
        gh.fail_after = 2
        with self.assertRaises(Interrupted):
            self.run_correction(gh)
        gh.items[DRAFT_ID]["assets"][0]["state"] = "starter"
        gh.actions.clear()
        with self.assertRaisesRegex(RuntimeError, "Incomplete"):
            self.run_correction(gh)
        self.assertEqual(gh.actions, [])

    def test_original_package_cannot_be_reused_as_corrected_package(self):
        target = next(iter(self.packages.values()))
        old_id, _ = correction.OLD_ASSETS[target.name]
        values = {**correction.OLD_ASSETS, target.name: (old_id, correction.digest(target))}
        with patch.object(correction, "OLD_ASSETS", values):
            gh = FakeGithub()
            with self.assertRaisesRegex(RuntimeError, "bytes equal"):
                self.run_correction(gh)
            self.assertEqual(gh.actions, [])


class LocalGitTest(unittest.TestCase):
    def test_alias_preserves_annotated_object_and_stale_lease_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.git"
            clone = root / "checkout"
            correction.git("init", "--bare", "--initial-branch=master", str(remote))
            correction.git("clone", str(remote), str(clone))

            def git(*args, **kwargs):
                return subprocess.check_output(["git", "-C", str(clone), *args], text=True,
                                               stderr=subprocess.STDOUT, **kwargs).strip()

            git("config", "user.email", "local@example.org")
            git("config", "user.name", "Local Test")
            git("commit", "--allow-empty", "-m", "Old")
            old_head = git("rev-parse", "HEAD")
            git("tag", "-a", correction.TAG, "-m", "Original")
            old_tag = git("rev-parse", correction.TAG)
            git("push", "origin", "master", T)
            git("commit", "--allow-empty", "-m", "Corrected")
            new_head = git("rev-parse", "HEAD")
            git("push", "origin", "master")
            new_tag = git("mktag", input=f"object {new_head}\ntype commit\ntag {correction.TAG}\n"
                          "tagger Local Test <local@example.org> 1720000000 +0000\n\nCorrected\n")
            with patch.object(correction, "git", git):
                client = correction.Github(new_head)
                client.set_tag(correction.ARCHIVE, old_tag, "")
                with self.assertRaises(subprocess.CalledProcessError):
                    client.set_tag(correction.TAG, new_tag, "0" * 40)
                self.assertEqual(client.refs()[T], old_tag)
                client.set_tag(correction.TAG, new_tag, old_tag)
                self.assertEqual(client.refs()[A], old_tag)
                self.assertEqual(client.refs()[T], new_tag)
                self.assertEqual(git("rev-parse", old_tag + "^{commit}"), old_head)
                self.assertEqual(git("rev-parse", new_tag + "^{commit}"), new_head)


if __name__ == "__main__":
    unittest.main()
