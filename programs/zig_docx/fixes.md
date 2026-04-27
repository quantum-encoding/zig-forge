# Fixes Log — zig_docx

## Wave 1 — 2026-04-27 — CRIT only

| ID | Status | Commit | Files | Description |
|---|---|---|---|---|
| C1 | RESOLVED | pending | src/zip.zig, src/docx.zig | DEFLATE bomb cap: per-entry 256 MB, archive-cumulative 1 GB; `inflate` now takes a `cap` and uses `.limited(cap)` so `allocRemaining` returns `error.StreamTooLong` on overflow. CD `uncompressed_size` (attacker-controlled) is no longer trusted; counter lives on `ZipArchive`, so `extract` is `*ZipArchive` and `parseDocument` follows. |
| C2 | RESOLVED | pending | src/anthropic.zig | Attachment `file_name` from `conversations.json` is now validated by `isSafeAttachmentName`: rejects empty / >255 / leading `.` / `/` / `\` / `\0`. On reject, the artifact is not written to disk; the markdown still lists the attachment for the user. Closes the zip-slip-via-JSON write that escaped `<output_dir>/artifacts/`. |
