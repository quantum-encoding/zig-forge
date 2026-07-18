// guardian_shield_lsm_memory.bpf.c
//
// SUPERSEDED by the v9 rebuild. The memory / privilege LSM hooks (ptrace,
// /dev/mem, module load, dangerous capabilities, mount ops) now live in the
// combined object bpf/guardian_shield.bpf.c, keyed on the PID-tree agent tag
// instead of bpf_get_current_comm. The non-existent lsm/task_setns and
// lsm/task_setuid hooks were dropped; sb_mount + move_mount cover mount ops.
//
// See V9_STATUS.md.
