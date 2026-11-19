"""Test builds listed in the Flutter release folder, shared by the publishing and worktree tools."""
import gzip
import json
import re

LOCK = ".preview.lock"
# Each file of a published app, and each build's list of them, stored once by
# the SHA-256 of its uncompressed content, so updates download only changed files.
STORE = "files"
STORED = re.compile(r"[0-9a-f]{64}\.gz")


def retire(releases, retiring):
    """Remove the listed test builds that `retiring(manifest)` selects, with the ZIPs
    and stored files no remaining build uses. Hold the feed lock while calling this."""
    retired, retained = {}, set()
    for path in releases.iterdir():
        if not re.fullmatch(r"preview-[a-z0-9][a-z0-9-]{0,62}\.json", path.name):
            continue
        manifest = json.loads(path.read_text())
        if retiring(manifest):
            retired[path] = manifest["file"]
        else:
            retained.add(manifest["file"])
    for path in retired:
        path.unlink()
    for filename in set(retired.values()) - retained:
        if re.fullmatch(r"Relay-Flutter-preview-[0-9a-f]{64}\.zip", filename):
            (releases / filename).unlink(missing_ok=True)
    prune(releases)
    return len(retired)


def prune(releases):
    """Remove the stored files and lists that neither latest.json nor a listed test
    build uses. Hold the feed lock while calling this."""
    store = releases / STORE
    if not store.exists():
        return
    used = set()
    for path in releases.iterdir():
        if path.name == "latest.json" or re.fullmatch(r"preview-[a-z0-9][a-z0-9-]{0,62}\.json", path.name):
            listed = json.loads(path.read_text()).get("fileList")
            if listed:
                used.add(listed["sha256"])
                entries = json.loads(gzip.decompress((store / f"{listed['sha256']}.gz").read_bytes()))
                used.update(entry["sha256"] for entry in entries if "sha256" in entry)
    for path in store.iterdir():
        if STORED.fullmatch(path.name) and path.name[:64] not in used:
            path.unlink()
