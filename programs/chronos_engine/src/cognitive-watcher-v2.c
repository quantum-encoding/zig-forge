// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - Cognitive Watcher V2
 *
 * Userspace program to attach cognitive-oracle-v2 kprobe and consume TTY events
 * Features: Deduplication, SQLite persistence, state extraction
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/resource.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include <sqlite3.h>
#include <openssl/sha.h>

#define MAX_COMM_LEN 16
#define MAX_BUF_SIZE 256
#define MAX_TTY_NAME 32

struct cognitive_event_v2 {
    __u32 pid;
    __u32 timestamp_ns;
    __u32 buf_size;
    __u32 _padding;
    char comm[MAX_COMM_LEN];
    char tty_name[MAX_TTY_NAME];
    char buffer[MAX_BUF_SIZE];
} __attribute__((packed));

static volatile bool exiting = false;
static long event_count = 0;
static long events_saved = 0;
static long events_deduped = 0;
static sqlite3 *db = NULL;

// State tracking for deduplication
struct last_state {
    char content_hash[65];  // SHA256 hex string
    char tool_name[128];
    char status[64];
    time_t timestamp;
} last_state = {0};

static void sig_handler(int sig)
{
    exiting = true;
}

static int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, format, args);
}

// Calculate SHA256 hash of content for deduplication
static void sha256_hash(const char *input, char *output)
{
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256((unsigned char*)input, strlen(input), hash);

    for (int i = 0; i < SHA256_DIGEST_LENGTH; i++) {
        sprintf(output + (i * 2), "%02x", hash[i]);
    }
    output[64] = '\0';
}

// Initialize SQLite database
static int init_database(const char *db_path)
{
    int rc = sqlite3_open(db_path, &db);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "Cannot open database: %s\n", sqlite3_errmsg(db));
        return -1;
    }

    // Read and execute schema
    FILE *schema_file = fopen("cognitive-states-schema.sql", "r");
    if (!schema_file) {
        fprintf(stderr, "Warning: Cannot open schema file, creating minimal schema\n");
        // Minimal schema as fallback
        const char *minimal_schema =
            "CREATE TABLE IF NOT EXISTS cognitive_states ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "timestamp_ns INTEGER NOT NULL,"
            "timestamp_human TEXT NOT NULL,"
            "pid INTEGER NOT NULL,"
            "process_name TEXT NOT NULL,"
            "state_type TEXT NOT NULL,"
            "tool_name TEXT,"
            "tool_args TEXT,"
            "status TEXT,"
            "raw_content TEXT NOT NULL,"
            "content_hash TEXT NOT NULL UNIQUE,"
            "created_at DATETIME DEFAULT CURRENT_TIMESTAMP);"
            "CREATE INDEX IF NOT EXISTS idx_content_hash ON cognitive_states(content_hash);";

        char *err_msg = NULL;
        rc = sqlite3_exec(db, minimal_schema, NULL, NULL, &err_msg);
        if (rc != SQLITE_OK) {
            fprintf(stderr, "SQL error: %s\n", err_msg);
            sqlite3_free(err_msg);
            return -1;
        }
    } else {
        // Execute full schema
        fseek(schema_file, 0, SEEK_END);
        long schema_size = ftell(schema_file);
        fseek(schema_file, 0, SEEK_SET);

        char *schema = malloc(schema_size + 1);
        fread(schema, 1, schema_size, schema_file);
        schema[schema_size] = '\0';
        fclose(schema_file);

        char *err_msg = NULL;
        rc = sqlite3_exec(db, schema, NULL, NULL, &err_msg);
        free(schema);

        if (rc != SQLITE_OK) {
            fprintf(stderr, "SQL error: %s\n", err_msg);
            sqlite3_free(err_msg);
            return -1;
        }
    }

    printf("✓ Database initialized\n");
    return 0;
}

// Parse cognitive state from buffer
static void parse_state(const char *buffer, char *tool_name, char *tool_args, char *status)
{
    // Initialize outputs
    tool_name[0] = '\0';
    tool_args[0] = '\0';
    status[0] = '\0';

    // Pattern: "Tool(args)\n   Status"
    // Example: "Bash(sudo bpftool...)\n   Running"

    const char *paren_open = strchr(buffer, '(');
    const char *paren_close = strrchr(buffer, ')');
    const char *newline = strchr(buffer, '\n');

    // Extract tool name (before opening paren)
    if (paren_open) {
        size_t tool_len = paren_open - buffer;
        if (tool_len > 0 && tool_len < 127) {
            // Skip leading whitespace
            while (*buffer == ' ' || *buffer == '\n' || *buffer == '\r') {
                buffer++;
                tool_len--;
            }
            strncpy(tool_name, buffer, tool_len);
            tool_name[tool_len] = '\0';
        }
    }

    // Extract tool args (between parens)
    if (paren_open && paren_close && paren_close > paren_open) {
        size_t args_len = paren_close - paren_open - 1;
        if (args_len > 0 && args_len < 1023) {
            strncpy(tool_args, paren_open + 1, args_len);
            tool_args[args_len] = '\0';
        }
    }

    // Extract status (after newline)
    if (newline) {
        const char *status_start = newline + 1;
        while (*status_start == ' ' || *status_start == '\t') {
            status_start++;
        }
        strncpy(status, status_start, 63);
        status[63] = '\0';
        // Trim trailing whitespace
        char *end = status + strlen(status) - 1;
        while (end > status && (*end == ' ' || *end == '\n' || *end == '\r')) {
            *end = '\0';
            end--;
        }
    }
}

// Save state to database with deduplication
static int save_state(const struct cognitive_event_v2 *e, const char *clean_content)
{
    char content_hash[65];
    char tool_name[128];
    char tool_args[1024];
    char status[64];

    // Parse the state
    parse_state(clean_content, tool_name, tool_args, status);

    // Calculate hash for deduplication
    char normalized[2048];
    snprintf(normalized, sizeof(normalized), "%s|%s|%s", tool_name, tool_args, status);
    sha256_hash(normalized, content_hash);

    // Check if this is a duplicate of the last state
    // ALWAYS save to ensure chronos-stamp gets the latest state
    // (We need current state, not just state changes)
    if (strcmp(content_hash, last_state.content_hash) == 0) {
        events_deduped++;
        // Continue anyway to update timestamp
    }

    // Prepare SQL statement
    const char *sql = "INSERT OR IGNORE INTO cognitive_states "
                      "(timestamp_ns, timestamp_human, pid, process_name, state_type, "
                      "tool_name, tool_args, status, raw_content, content_hash) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

    sqlite3_stmt *stmt;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "Failed to prepare statement: %s\n", sqlite3_errmsg(db));
        return -1;
    }

    // Convert timestamp to human readable
    char timestamp_human[64];
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    strftime(timestamp_human, sizeof(timestamp_human), "%Y-%m-%d %H:%M:%S", tm_info);

    // Bind parameters
    sqlite3_bind_int64(stmt, 1, e->timestamp_ns);
    sqlite3_bind_text(stmt, 2, timestamp_human, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 3, e->pid);
    sqlite3_bind_text(stmt, 4, e->comm, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, tool_name[0] ? "tool_execution" : "unknown", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, tool_name[0] ? tool_name : NULL, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, tool_args[0] ? tool_args : NULL, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, status[0] ? status : NULL, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 9, clean_content, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 10, content_hash, -1, SQLITE_TRANSIENT);

    rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) {
        if (rc == SQLITE_CONSTRAINT) {
            // Duplicate hash, already in DB
            events_deduped++;
            return 0;
        }
        fprintf(stderr, "Failed to insert: %s\n", sqlite3_errmsg(db));
        return -1;
    }

    // Update last state
    strcpy(last_state.content_hash, content_hash);
    strcpy(last_state.tool_name, tool_name);
    strcpy(last_state.status, status);
    last_state.timestamp = now;

    events_saved++;
    return 1;  // Successfully saved
}

// Strip ANSI escape sequences from buffer
static void strip_ansi(char *output, const char *input, size_t len)
{
    size_t i = 0, j = 0;

    while (i < len && input[i] != '\0') {
        // Detect ANSI CSI sequence: ESC [ ... letter
        if (i + 1 < len && input[i] == 0x1b && input[i + 1] == '[') {
            i += 2;
            while (i < len && input[i] != '\0') {
                char ch = input[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
                    i++;
                    break;
                }
                i++;
            }
            continue;
        }

        // Detect ANSI OSC sequence: ESC ] ... BEL or ST
        if (i + 1 < len && input[i] == 0x1b && input[i + 1] == ']') {
            i += 2;
            while (i < len && input[i] != '\0' && input[i] != 0x07) {
                i++;
            }
            if (i < len && input[i] == 0x07) i++;
            continue;
        }

        // Keep printable characters, newlines, tabs
        char ch = input[i];
        if (ch >= 32 || ch == '\n' || ch == '\t') {
            output[j++] = ch;
        }
        i++;
    }
    output[j] = '\0';
}

// Check if buffer contains cognitive state keywords
static int detect_cognitive_state(const char *buffer, size_t len)
{
    const char *keywords[] = {
        "Testing", "Channelling", "Thinking", "Pondering",
        "Finagling", "Calculating", "Analyzing", "Building",
        "Compiling", "Running", "Verifying", "Checking",
        "Creating", "Writing", "Reading", "Editing", NULL
    };

    for (int i = 0; keywords[i] != NULL; i++) {
        if (strstr(buffer, keywords[i]) != NULL) {
            return 1;
        }
    }
    return 0;
}

static int handle_event(void *ctx, void *data, size_t data_sz)
{
    const struct cognitive_event_v2 *e = data;
    event_count++;

    // Strip ANSI codes
    char clean_buffer[MAX_BUF_SIZE + 1];
    strip_ansi(clean_buffer, e->buffer, e->buf_size < MAX_BUF_SIZE ? e->buf_size : MAX_BUF_SIZE);

    // Save ALL output - no keyword filtering
    // Let the extraction script decide what's a status line
    printf("🧠 TTY OUTPUT #%ld [PID=%u]:\n", event_count, e->pid);
    printf("   %s\n", clean_buffer);

    // Save to database
    int saved = save_state(e, clean_buffer);
    if (saved > 0) {
        printf("   💾 Saved to database (total: %ld, deduped: %ld)\n", events_saved, events_deduped);
    } else if (saved == 0) {
        printf("   ⏭️  Skipped (duplicate)\n");
    }

    // Stats every 1000 events
    if (event_count % 1000 == 0) {
        printf("📊 Stats: %ld events (%ld saved, %ld deduped)\n",
               event_count, events_saved, events_deduped);
    }

    return 0;
}

int main(int argc, char **argv)
{
    struct bpf_object *obj;
    struct bpf_program *prog;
    struct bpf_link *link = NULL;
    struct ring_buffer *rb = NULL;
    int map_fd, config_fd;
    int err;

    // Set up libbpf logging
    libbpf_set_print(libbpf_print_fn);

    // Install signal handlers
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    printf("🔮 COGNITIVE WATCHER V2 - Terminal Subsystem Mode\n");
    printf("💾 Database: cognitive-states.db\n");

    // Initialize database
    if (init_database("cognitive-states.db") < 0) {
        return 1;
    }

    printf("⚡ Loading eBPF program...\n");

    // Open and load BPF object
    obj = bpf_object__open_file("cognitive-oracle-v2.bpf.o", NULL);
    if (!obj) {
        fprintf(stderr, "Failed to open BPF object: %s\n", strerror(errno));
        return 1;
    }

    err = bpf_object__load(obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF object: %s\n", strerror(-err));
        goto cleanup;
    }

    printf("✓ BPF object loaded\n");

    // Find the kprobe program
    prog = bpf_object__find_program_by_name(obj, "probe_tty_write");
    if (!prog) {
        fprintf(stderr, "Failed to find probe_tty_write program\n");
        goto cleanup;
    }

    // Attach kprobe to tty_write
    printf("⚡ Attaching kprobe to tty_write...\n");
    link = bpf_program__attach(prog);
    if (!link) {
        fprintf(stderr, "Failed to attach kprobe: %s\n", strerror(errno));
        goto cleanup;
    }

    printf("✓ Kprobe attached to tty_write\n");

    // Get config map and enable oracle
    config_fd = bpf_object__find_map_fd_by_name(obj, "cognitive_config_v2");
    if (config_fd < 0) {
        fprintf(stderr, "Failed to find config map\n");
        goto cleanup;
    }

    __u32 key = 0;
    __u32 enabled = 1;
    err = bpf_map_update_elem(config_fd, &key, &enabled, BPF_ANY);
    if (err) {
        fprintf(stderr, "Failed to enable oracle: %s\n", strerror(-err));
        goto cleanup;
    }

    printf("✓ Cognitive oracle enabled\n");

    // Set up ring buffer
    map_fd = bpf_object__find_map_fd_by_name(obj, "cognitive_events_v2");
    if (map_fd < 0) {
        fprintf(stderr, "Failed to find ring buffer map\n");
        goto cleanup;
    }

    rb = ring_buffer__new(map_fd, handle_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "Failed to create ring buffer: %s\n", strerror(errno));
        goto cleanup;
    }

    printf("✓ Ring buffer ready\n");
    printf("🔮 Beginning eternal vigil over the phantom's whispers...\n");
    printf("   (Press Ctrl+C to stop)\n\n");

    // Main event loop
    while (!exiting) {
        err = ring_buffer__poll(rb, 100 /* timeout, ms */);
        if (err == -EINTR) {
            err = 0;
            break;
        }
        if (err < 0) {
            fprintf(stderr, "Error polling ring buffer: %s\n", strerror(-err));
            break;
        }
    }

    printf("\n🛑 Shutting down...\n");
    printf("📊 Final Stats:\n");
    printf("   Total events: %ld\n", event_count);
    printf("   States saved: %ld\n", events_saved);
    printf("   Duplicates skipped: %ld\n", events_deduped);

cleanup:
    ring_buffer__free(rb);
    bpf_link__destroy(link);
    bpf_object__close(obj);

    if (db) {
        sqlite3_close(db);
        printf("💾 Database closed\n");
    }

    return err != 0;
}
