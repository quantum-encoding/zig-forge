// guardian_shield_lsm_filesystem.bpf.c
//
// SUPERSEDED by the v9 rebuild. The filesystem LSM hooks now live in the single
// combined object bpf/guardian_shield.bpf.c, which fixes the FATAL leaf-only
// path bug (get_dentry_path read only dentry->d_name.name) via mount-aware
// absolute path reconstruction + bpf_d_path, replaces the forgeable
// bpf_get_current_comm identity with a PID-tree agent tag, and swaps the
// unrolled linear path scan for an LPM trie.
//
// This file is intentionally left as a redirect so the old, broken program is
// no longer compiled or attached. See V9_STATUS.md.
