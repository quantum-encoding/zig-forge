/*
 * es_core.h — one C ABI over Apple EndpointSecurity, implemented twice.
 *
 *   zes_*  Zig   zig-forge/programs/zig_endpoint_sec/src/capi.zig    (libes_core_zig.a)
 *   res_*  Rust  GuardianShield/es-core/rust over the HarfangLab endpoint-sec crate (libes_core_rust.a)
 *
 * Both backends expose exactly the functions declared by ESC_DECLARE below, so a
 * Swift host can drive either through the same shape and benchmark them against
 * its own native ES code. Everything is plain C: opaque handles, int result codes
 * that mirror the ES enums, and pointer+length strings that borrow from the message.
 *
 * Ownership and lifetime rules (identical for both backends):
 *   - The message passed to the handler, and every esc_str inside the esc_event,
 *     are valid until the handler returns. To keep a message longer (answer an
 *     AUTH event later) call *_message_retain before returning and *_message_release
 *     when done; strings obtained from a retained message stay valid until release.
 *   - AUTH messages must be answered with *_respond / *_respond_auth / *_respond_flags
 *     before ev->deadline (mach_absolute_time ticks; see *_now_ticks / *_ticks_to_ns).
 *   - *_client_delete must not be called from inside the handler.
 *
 * Result codes:
 *   *_client_new           es_new_client_result_t (0 = success, 3 = not entitled, 4 = not permitted, 5 = not privileged, 6 = too many clients)
 *   *_respond_*            es_respond_result_t (0 = success)
 *   *_clear_cache          es_clear_cache_result_t (0 = success)
 *   everything else        es_return_t (0 = success, 1 = error)
 *   negative               shim-level: ESC_ERR_API_UNAVAILABLE, ESC_ERR_INVALID_ARGUMENT, ESC_ERR_OUT_OF_MEMORY, ESC_ERR_UNKNOWN_EVENT
 */
#ifndef ES_CORE_H
#define ES_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ESC_ABI_VERSION = 1,

    ESC_ERR_API_UNAVAILABLE = -1,   /* the running macOS lacks the ES function */
    ESC_ERR_INVALID_ARGUMENT = -2,  /* NULL, bad length, path not representable */
    ESC_ERR_OUT_OF_MEMORY = -3,
    ESC_ERR_UNKNOWN_EVENT = -4,     /* decode: header filled, payload not understood */
};

typedef struct esc_client esc_client;   /* one ES client of one backend */
typedef struct esc_message esc_message; /* an es_message_t; opaque to the host */

/* Borrowed bytes; not NUL-terminated. len == 0 means absent. */
typedef struct esc_str {
    const char *ptr;
    size_t len;
} esc_str;

/* audit_token_t */
typedef struct esc_audit_token {
    uint32_t val[8];
} esc_audit_token;

/*
 * The decoded view of one message that every backend must produce for the
 * handler. This is the unit of work the benchmark compares: the fields a
 * monitoring extension reads on every event, extracted once, zero-copy.
 *
 * Which paths land where:
 *   exec        target_path = new image, target_pid = new pid, argc, target_path2 = cwd
 *   open/close/write/truncate/…  target_path = the file (flags = fflag for open)
 *   create      target_path = existing file, or target_path2 = dir + name = filename
 *   unlink      target_path = file, target_path2 = parent dir
 *   rename      target_path = source, then existing dest in target_path2 or dir in target_path2 + name
 *   link/clone/copyfile  target_path = source, target_path2 = target dir, name = new name
 *   exchangedata target_path = file1, target_path2 = file2
 *   *extattr    target_path = file, name = attribute
 *   lookup      target_path = source dir, name = relative target
 *   fork        target_pid = child;  exit: status;  signal: status = signal, target_pid = victim
 *   mount/unmount/remount  target_path = mount point, target_path2 = mounted-from
 *   kextload/kextunload    name = bundle id;  iokit_open: name = user client class
 */
typedef struct esc_event {
    uint32_t abi_version;      /* ESC_ABI_VERSION */
    uint32_t event_type;       /* es_event_type_t */
    uint32_t message_version;  /* es_message_t.version */
    uint32_t argc;             /* exec only */
    uint32_t flags;            /* open: fflag; access: mode; fcntl: cmd; setmode: mode; setflags: flags; pty: dev */
    int32_t  status;           /* exit status; signal number */

    uint8_t  is_auth;
    uint8_t  is_platform_binary;         /* message.process */
    uint8_t  is_es_client;               /* message.process */
    uint8_t  target_is_platform_binary;  /* exec target */

    int32_t  pid;
    int32_t  ppid;
    int32_t  original_ppid;
    int32_t  responsible_pid;   /* -1 when the message version predates it */
    int32_t  parent_pid;        /* -1 when the message version predates it */
    int32_t  target_pid;        /* exec target, fork child, signal/get_task/trace target; 0 if none */

    uint64_t mach_time;
    uint64_t deadline;
    uint64_t seq_num;           /* 0 when absent */
    uint64_t global_seq_num;    /* 0 when absent */

    esc_audit_token audit_token;

    esc_str process_path;
    esc_str signing_id;
    esc_str team_id;
    esc_str target_path;
    esc_str target_path2;
    esc_str name;
} esc_event;

typedef void (*esc_handler)(void *ctx, esc_client *client, esc_message *msg, const esc_event *ev);

#define ESC_DECLARE(P) \
    /* "zig 0.1.0 / SDK …" or "rust endpoint-sec 0.6.2" — for labelling benchmark output. */ \
    esc_str  P##_version(void); \
    int      P##_client_new(esc_client **out, esc_handler handler, void *ctx); \
    int      P##_client_delete(esc_client *c); \
    int      P##_subscribe(esc_client *c, const uint32_t *events, uint32_t count); \
    int      P##_unsubscribe_all(esc_client *c); \
    int      P##_respond_auth(esc_client *c, esc_message *m, uint32_t es_auth_result, bool cache); \
    int      P##_respond_flags(esc_client *c, esc_message *m, uint32_t authorized_flags, bool cache); \
    /* allow/deny with the right respond function for the event type (AUTH_OPEN takes flags). */ \
    int      P##_respond(esc_client *c, esc_message *m, bool allow, bool cache); \
    int      P##_mute_process(esc_client *c, const esc_audit_token *token); \
    int      P##_unmute_process(esc_client *c, const esc_audit_token *token); \
    int      P##_mute_self(esc_client *c); \
    int      P##_mute_path(esc_client *c, const char *path, uint32_t es_mute_path_type); \
    int      P##_unmute_all_paths(esc_client *c); \
    int      P##_unmute_all_target_paths(esc_client *c); \
    int      P##_invert_muting(esc_client *c, uint32_t es_mute_inversion_type); \
    int      P##_clear_cache(esc_client *c); \
    int      P##_set_deadline_miss_mode(esc_client *c, uint32_t es_deadline_miss_mode); \
    void     P##_message_retain(esc_message *m); \
    void     P##_message_release(esc_message *m); \
    /* Fill *out from the message. Same work the handler does before calling you. */ \
    int      P##_decode(const esc_message *m, esc_event *out); \
    uint32_t P##_exec_arg_count(const esc_message *m); \
    esc_str  P##_exec_arg(const esc_message *m, uint32_t index); \
    uint32_t P##_exec_env_count(const esc_message *m); \
    esc_str  P##_exec_env(const esc_message *m, uint32_t index); \
    /* Value of NAME in the exec environment, or len 0. */ \
    esc_str  P##_exec_find_env(const esc_message *m, const char *name); \
    uint64_t P##_now_ticks(void); \
    uint64_t P##_ticks_to_ns(uint64_t ticks);

ESC_DECLARE(zes)
ESC_DECLARE(res)

#ifdef __cplusplus
}
#endif
#endif /* ES_CORE_H */
