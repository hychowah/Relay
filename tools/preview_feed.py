"""Test builds listed in the Flutter release folder, shared by the publishing and worktree tools."""
import json
import re

LOCK = ".preview.lock"


def retire(releases, retiring):
    """Remove the listed test builds that `retiring(manifest)` selects, with the ZIPs
    no remaining build uses. Hold the feed lock while calling this."""
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
    return len(retired)
