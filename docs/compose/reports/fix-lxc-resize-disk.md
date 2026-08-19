---
feature: fix-lxc-resize-disk
status: delivered
specs: []
plans:
  - .mimocode/plans/1787140086299-witty-orchid.md
branch: feat/lxc-resize-disk
commits: 488fcb76..HEAD
---

# Fix lxc-resize-disk.sh — Final Report

## What Was Built

Five targeted fixes to `tools/pve/lxc-resize-disk.sh` to improve error reporting and prevent silent failures:

1. **ERR trap** — Unhandled errors now display the failing command, line number, and exit code before exiting, instead of silently dying.
2. **pvesm path validation** — `create_new_volume()` now catches empty path resolution for dir/nfs/cifs storage and displays the actual `pvesm path` error instead of producing `truncate: cannot open '' for writing`.
3. **dd stderr capture** — `copy_data()` redirects dd stderr to a temp file and displays it on failure, instead of swallowing errors.
4. **Checksum mismatch details** — `verify_checksum()` now shows the actual source and dest hashes when they don't match.
5. **Copy failure context** — The copy_data error path in `resize_via_dd()` now shows source/dest paths and sizes alongside the exit code.

## Architecture

Single file change: `tools/pve/lxc-resize-disk.sh`. No new files, no dependencies added. All fixes are local to existing functions.

## Verification

- `bash -n` — syntax check passes
- `shellcheck -s bash` — exit 0, no warnings
