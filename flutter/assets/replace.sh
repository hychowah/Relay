#!/bin/bash
set -u
target=$1
candidate=$2
backup=$3
parent_pid=$4
receipt=$5
failed=$6

if [ "$(basename "$target")" != 'Relay Flutter.app' ]; then
  echo 'Unexpected application path; no files changed.'
  exit 1
fi
for ((i=0; i<30; i++)); do
  if ! kill -0 "$parent_pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$parent_pid" 2>/dev/null; then
  echo 'Relay did not close; no files changed.'
  exit 1
fi
if ! mv "$target" "$backup"; then
  echo 'Could not save the old app; no replacement installed.'
  /usr/bin/open -n "$target"
  exit 1
fi
restore() {
  if [ -e "$target" ]; then mv "$target" "$failed" || return 1; fi
  mv "$backup" "$target" || return 1
  echo 'Restored the previous version of Relay.'
  /usr/bin/open -n "$target"
}
if ! mv "$candidate" "$target"; then
  echo 'Could not install the downloaded app.'
  restore
  exit 1
fi
if ! /usr/bin/open -n "$target"; then
  echo 'macOS did not launch the new version.'
  restore
  exit 1
fi
for ((i=0; i<45; i++)); do
  if [ -f "$receipt" ]; then echo 'Update launched successfully.'; exit 0; fi
  sleep 1
done
# A security prompt may still be open. Keep both bundles rather than moving a
# possibly running app. The next version to start removes the previous bundle.
echo 'No launch confirmation. The previous app remains in the backup folder.'
exit 1
