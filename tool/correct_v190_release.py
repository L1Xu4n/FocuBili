"""One-time build-32 correction from the ordinary exact-SHA publisher.

The original release must have no assets: its owner removed the old packages.
Preserve its notes and exact tagged source, never recreate any removed files.
The canonical tag moves only after a verified draft and source archive exist.
Rerun the same Actions run to resume.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

REPO = "L1Xu4n/FocuBili"
MASTER = "refs/heads/master"
TAG = "v1.9.0"
ARCHIVE = TAG + "-archive-build2038"
STAGE = TAG + "-correction-build32-draft"
TITLE = "FocuBili v1.9.0"
ARCHIVE_TITLE = TITLE + "（已归档，原构建 2038）"
OLD_SHA = "37e1de3f67e48d423c73c152529720b250a75cb6"
OLD_TAG = "695bba27ddd123da51e6bc32febf958efdab33dc"
OLD_ID = 453825715
OLD_NOTES_SHA256 = "932895d01a10071db17c1e845bb6a3bbbcf79b334696f0d31c6946411decfc7a"
OLD_ASSETS = {
    "android.apk": (776174660, "5f8bdaf4fc45f53a74ff4b5765cd2fce29c823a263f9bf418b3ed6d23a6155ec"),
    "ios-unsigned.ipa": (776174659, "cab3a9c1c3944026adc044956549cf66a1699fbd26dffb947fe7500d7bc87e76"),
    "linux-amd64.deb": (776174656, "fc4d6ea1921e174203381bdb8306d0ff1c4eb6dfb0413dee3b9b37e8231b2aa9"),
    "macos-universal.dmg": (776174650, "8f9768ec1b7c04f9fbdf6e968f9750b10e14b8e27def6b524e829ca6bdedd944"),
    "windows-x64-portable.zip": (776174658, "3c5e8e44247e1d5cc634b89d98c3a9ce35260b7d4f3b8de49860a49cb3a69d9f"),
    "windows-x64-setup.exe": (776174704, "a51bf64b214d407495f3fc2b6b4941c048ff9e972f1ebec581e833139dc33f00"),
}
OLD_ASSETS = {
    f"FocuBili-{TAG}-{name}": (asset_id, "sha256:" + sha)
    for name, (asset_id, sha) in OLD_ASSETS.items()
}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def git(*args, **kwargs):
    return command("git", *args, **kwargs)


def digest(path):
    with path.open("rb") as src:
        return "sha256:" + hashlib.file_digest(src, "sha256").hexdigest()


def tag_ref(name):
    return "refs/tags/" + name


def api(path, payload=None, method="GET"):
    args = ["gh", "api", "--method", method, "-H", "Accept: application/vnd.github+json",
            f"repos/{REPO}/{path}"]
    if payload is None:
        return json.loads(command(*args))
    return json.loads(command(*args, "--input", "-", input=json.dumps(payload)))


def normalized_notes(notes):
    require(isinstance(notes, str), "Missing release notes")
    # GitHub's web editor may turn only LF into CRLF on a maintainer's save.
    return notes.replace("\r\n", "\n").strip()


def archive_body(notes):
    return (f"> 此归档仅保留原构建 `2038` 的源码和发布说明；原安装包已由维护者移除。"
            f"请下载 [正式版 v1.9.0](https://github.com/{REPO}/releases/tag/{TAG})。\n\n"
            f"原始源码：`{OLD_SHA}`；原始 annotated tag 对象：`{OLD_TAG}`。\n\n---\n\n{notes}")


def assets(release):
    entries = {a["name"]: a for a in release["assets"]}
    require(len(entries) == len(release["assets"]) == len({a["id"] for a in entries.values()}),
            "Duplicate package name or ID")
    require(all(a.get("state") == "uploaded" and a.get("size", 0) > 0 for a in entries.values()),
            "Incomplete or empty asset; inspect the draft without deleting or overwriting")
    return entries


class Github:
    def __init__(self, head):
        self.head = head

    def refs(self):
        result = git("ls-remote", "--refs", "origin", MASTER,
                     tag_ref(TAG), tag_ref(ARCHIVE), tag_ref(STAGE))
        return {ref: sha for sha, ref in (line.split() for line in result.splitlines())}

    def guard_master(self):
        require(self.refs().get(MASTER) == self.head, "Master moved from the verified SHA")

    def releases(self):
        result = command("gh", "api", f"repos/{REPO}/releases?per_page=100",
                         "--paginate", "--jq", ".[]")
        return [json.loads(line) for line in result.splitlines()]

    def release(self, release_id):
        return api(f"releases/{release_id}")

    def latest(self):
        return api("releases/latest")["id"]

    def create(self, payload):
        self.guard_master()
        return api("releases", payload, "POST")

    def patch(self, release_id, payload):
        self.guard_master()
        return api(f"releases/{release_id}", payload, "PATCH")

    def upload(self, release_id, path):
        self.guard_master()
        url = f"https://uploads.github.com/repos/{REPO}/releases/{release_id}/assets?name={quote(path.name)}"
        return json.loads(command("gh", "api", "--method", "POST", url,
                                  "-H", "Content-Type: application/octet-stream",
                                  "-H", f"Content-Length: {path.stat().st_size}", "--input", str(path)))

    def verify_bytes(self, release, asset):
        require(release.get("draft") is True, "Can only verify corrected draft assets")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "asset"
            with path.open("wb") as out:
                subprocess.run(["gh", "api", f"repos/{REPO}/releases/assets/{asset['id']}",
                                "-H", "Accept: application/octet-stream"], stdout=out, check=True)
            require(path.stat().st_size == asset["size"] and digest(path) == asset["digest"],
                    f"Downloaded bytes do not match: {asset['name']}")

    def set_tag(self, name, new, old):
        self.guard_master()
        ref = tag_ref(name)
        git("push", "--porcelain", f"--force-with-lease={ref}:{old}", "origin", f"{new}:{ref}")
        require(self.refs().get(ref) == new, f"Ref did not read back: {ref}")


def correct(gh, head, new_tag, notes, old_notes, packages, evidence):
    # Record identities so an interrupted run can be inspected before a retry.
    evidence.mkdir(parents=True, exist_ok=True)

    def record(filename, value):
        (evidence / filename).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n",
                                         encoding="utf-8")

    expected = {name: (path.stat().st_size, digest(path)) for name, path in packages.items()}
    require(set(expected) == set(OLD_ASSETS), "Wrong corrected asset set")
    require(all(size > 0 and sha != OLD_ASSETS[name][1] for name, (size, sha) in expected.items()),
            "Empty corrected package, or bytes equal an original package")
    record("expected.json", {"head": head, "new_tag_object": new_tag,
                            "old_tag_object": OLD_TAG, "corrected_packages": expected})

    def read_refs():
        refs = gh.refs()
        canonical, archive = refs.get(tag_ref(TAG)), refs.get(tag_ref(ARCHIVE))
        require(refs.get(MASTER) == head, "Master moved from the verified SHA")
        require(canonical in (OLD_TAG, new_tag) and archive in (None, OLD_TAG)
                and not refs.get(tag_ref(STAGE)), "Unexpected remote tag state")
        return canonical, archive

    def old_release():
        old = gh.release(OLD_ID)
        archived = old.get("tag_name") == ARCHIVE
        require(old["id"] == OLD_ID and old.get("immutable") is False
                and old.get("draft") is False and old.get("prerelease") is archived
                and old.get("tag_name") in (TAG, ARCHIVE)
                # The exact archived tag object (not this advisory REST field)
                # pins the commit when the destination tag already exists.
                and old.get("target_commitish") in (("master", OLD_SHA) if archived else ("master",))
                and old.get("name") == (ARCHIVE_TITLE if archived else TITLE)
                and normalized_notes(old.get("body")) == normalized_notes(archive_body(old_notes) if archived else old_notes),
                "Original release metadata does not match expected build-2038 state")
        require(old.get("assets") == [],
                "Owner-cleared original release must contain no assets; refusing changed inventory")
        return old, archived

    def corrected_release(release, *, name, draft, complete):
        require(release["id"] != OLD_ID and release.get("draft") is draft
                and (not draft or release.get("immutable") is False)
                and release.get("prerelease") is False
                and release.get("tag_name") == name
                and release.get("target_commitish") == head
                and release.get("name") == TITLE and normalized_notes(release.get("body")) == normalized_notes(notes),
                "Corrected release is not the verified draft or final release")
        current = assets(release)
        require(current.keys() <= expected.keys() and (not complete or current.keys() == expected.keys())
                and all((a["size"], a["digest"]) == expected[name]
                        and a["id"] not in {asset_id for asset_id, _ in OLD_ASSETS.values()}
                        for name, a in current.items()),
                "Staged package inventory, size, or digest mismatch")
        return current

    canonical, backup_ref = read_refs()
    old, archived = old_release()
    record("previous-release.json" if not archived else "archived-release.json", old)
    matches = {name: [] for name in (STAGE, TAG, ARCHIVE)}
    for candidate in gh.releases():
        if candidate["id"] != OLD_ID and candidate["tag_name"] in matches:
            matches[candidate["tag_name"]].append(candidate)
    require(not matches[ARCHIVE] and len(matches[STAGE]) <= 1 and len(matches[TAG]) <= 1,
            "Unexpected release exists at the archive, staging, or canonical tag")
    require((not archived or backup_ref == OLD_TAG) and (canonical == OLD_TAG or archived),
            "Canonical tag changed before the original release and tag were archived")

    canonical_draft = None
    if matches[TAG]:
        require(archived and canonical == new_tag and not matches[STAGE],
                "Canonical release exists while correction is incomplete")
        done = gh.release(matches[TAG][0]["id"])
        if done.get("draft") is False:
            corrected_release(done, name=TAG, draft=False, complete=True)
            require(gh.latest() == done["id"], "Corrected release is not repository latest")
            record("corrected-release.json", done)
            return
        corrected_release(done, name=TAG, draft=True, complete=True)
        canonical_draft = done

    if not archived:
        require(gh.latest() == OLD_ID, "Another release became latest; refusing to replace latest")

    if canonical_draft is not None:
        staged = canonical_draft
    elif matches[STAGE]:
        staged = gh.release(matches[STAGE][0]["id"])
    else:
        require(not archived and backup_ref is None, "Verified draft missing after archive creation")
        staged = gh.create({"tag_name": STAGE, "target_commitish": head, "name": TITLE,
                            "body": notes, "draft": True, "prerelease": False,
                            "make_latest": "false"})
    staged_name = TAG if canonical_draft is not None else STAGE
    current = corrected_release(staged, name=staged_name, draft=True,
                                complete=archived or backup_ref is not None)
    for name in expected.keys() - current.keys():
        gh.upload(staged["id"], packages[name])
    staged = gh.release(staged["id"])
    for asset in corrected_release(staged, name=staged_name, draft=True, complete=True).values():
        gh.verify_bytes(staged, asset)
    record("verified-draft.json", staged)
    print(f"Verified six corrected draft assets on release {staged['id']}", flush=True)

    # Archive is a real remote ref to the same annotated tag object. It protects
    # the original source even if the workflow stops after moving the release.
    require(read_refs() == (canonical, backup_ref), "Remote refs changed during staging")
    if backup_ref is None:
        gh.set_tag(ARCHIVE, OLD_TAG, "")
    if not archived:
        require(gh.latest() == OLD_ID and old_release()[1] is False,
                "Original release changed before archive")
        gh.patch(OLD_ID, {"tag_name": ARCHIVE, "target_commitish": OLD_SHA,
                          "name": ARCHIVE_TITLE, "body": archive_body(old_notes),
                          "prerelease": True, "make_latest": "false"})
    old_after, archived = old_release()
    require(archived and gh.latest() != OLD_ID, "Original release did not become a non-latest archive")
    record("archived-release.json", old_after)
    print(f"Preserved the owner-cleared release and annotated source at {ARCHIVE}", flush=True)

    require(read_refs() == (canonical, OLD_TAG), "Remote refs changed during archive verification")
    if canonical == OLD_TAG:
        gh.set_tag(TAG, new_tag, OLD_TAG)
    require(read_refs() == (new_tag, OLD_TAG), "Tag promotion not verified")
    corrected_release(gh.release(staged["id"]), name=staged_name, draft=True, complete=True)
    if staged_name == STAGE:
        gh.patch(staged["id"], {"tag_name": TAG, "target_commitish": head,
                                "draft": True, "make_latest": "false"})
    canonical_draft = gh.release(staged["id"])
    corrected_release(canonical_draft, name=TAG, draft=True, complete=True)
    record("canonical-draft.json", canonical_draft)
    require(read_refs() == (new_tag, OLD_TAG) and old_release()[1],
            "Tag or owner-cleared archive changed before publishing verified draft")
    gh.patch(staged["id"], {"draft": False, "prerelease": False, "make_latest": "true"})
    done = gh.release(staged["id"])
    corrected_release(done, name=TAG, draft=False, complete=True)
    require(gh.latest() == done["id"], "Corrected release is not repository latest")
    record("corrected-release.json", done)
    print(f"Published and verified {TAG} at {head}; archived the original build", flush=True)


def main():
    head = os.environ.get("GITHUB_SHA", "")
    require(os.environ.get("GITHUB_REPOSITORY") == REPO
            and os.environ.get("GITHUB_REF") == MASTER
            and os.environ.get("GITHUB_EVENT_NAME") == "push"
            and bool(re.fullmatch(r"[0-9a-f]{40}", head))
            and git("rev-parse", "HEAD") == head
            and git("show", "-s", "--format=%s", head) == "release: publish v1.9.0 build 32",
            "Only the exact trusted stable correction publish commit is allowed")
    require(re.findall(r"^version: (\S+)$", Path("pubspec.yaml").read_text(), re.MULTILINE) == ["1.9.0+32"],
            "Wrong stable correction version/build")
    git("merge-base", "--is-ancestor", OLD_SHA, head)
    require("version: 1.9.0+2038" in git("show", f"{OLD_SHA}:pubspec.yaml").splitlines(),
            "Pinned original source no longer identifies build 2038")
    gh = Github(head)
    refs = gh.refs()
    require(refs.get(MASTER) == head, "Master moved from the verified SHA")
    original_ref = next((ref for ref in (tag_ref(TAG), tag_ref(ARCHIVE))
                         if refs.get(ref) == OLD_TAG), None)
    require(original_ref is not None, "No ref protects the exact original annotated tag")
    git("fetch", "--no-tags", "origin", original_ref)
    require(git("cat-file", "-t", OLD_TAG) == "tag" and git("rev-parse", OLD_TAG + "^{commit}") == OLD_SHA,
            "Original annotated tag does not peel to the pinned original commit")
    # Deterministic annotated object, even when a workflow reruns on a fresh runner.
    timestamp = git("show", "-s", "--format=%ct", head)
    new_tag = git("mktag", input=f"object {head}\ntype commit\ntag {TAG}\n"
                  f"tagger github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> "
                  f"{timestamp} +0000\n\n{TITLE}\n")
    notes_file = "docs/RELEASE_NOTES_v1.9.0.md"
    old_notes = git("show", f"{OLD_SHA}:{notes_file}")
    require(hashlib.sha256(normalized_notes(old_notes).encode("utf-8")).hexdigest() == OLD_NOTES_SHA256,
            "Pinned original notes do not match the original public release")
    notes = Path(notes_file).read_text(encoding="utf-8")
    require("构建号 `2038`" in old_notes and "构建号 `32`" in notes, "Build notes do not match correction")
    packages = {p.name: p for p in Path("release").iterdir() if p.is_file()}
    correct(gh, head, new_tag, notes, old_notes, packages, Path("build/v190-correction"))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, KeyError, ValueError) as exc:
        sys.exit(str(exc))
