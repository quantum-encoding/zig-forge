// phasebench: run one zdedupe scan and print per-phase wall time and CPU use.
// usage: phasebench [-m mode] [-d] [-x] [-c] [-H] [-W] [-L secs] [-C secs] [-X path]... [-j threads]
//                   [-o store] [-J result.json] [-E export] PATH...
//   -m MODE 0 duplicates (default), 1 compare two folders, 2 disk space.
//   -d analyze directories, -x default excludes, -c credential excludes, -H hidden files.
//   -W stops after the walk. -j N threads (default: the core's choice).
//   -L SECS logs found/done rates, bytes read, stall, memory footprint and the longest-running path every SECS.
//   -C SECS cancels once one item has been stuck that long, and reports how fast the cancel returned.
//   -J FILE writes the run as JSON: total and per-phase wall and CPU seconds, peak RSS, and the
//           scan's overview (modes 0 and 2). bench.py beside this file reads it.
//   -E FILE writes what the scan found, for comparing two builds: the CSV export (mode 0), or the
//           compare report (mode 1).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/task_info.h>
#endif

typedef struct zdedupe_ctx zdedupe_ctx;
typedef struct zdedupe_results zdedupe_results;
typedef struct { uint32_t phase, _pad; uint64_t files_found, done, total, bytes_done, bytes_total, stalled_ms; } zdedupe_progress;
zdedupe_ctx* zdedupe_init(void);
void zdedupe_free(zdedupe_ctx*);
int zdedupe_add_path(zdedupe_ctx*, const char*);
void zdedupe_set_mode(zdedupe_ctx*, int);
void zdedupe_set_analyze_dirs(zdedupe_ctx*, bool);
void zdedupe_use_default_excludes(zdedupe_ctx*, bool);
void zdedupe_use_credential_excludes(zdedupe_ctx*, bool);
void zdedupe_set_threads(zdedupe_ctx*, uint32_t);
void zdedupe_set_include_hidden(zdedupe_ctx*, bool);
int zdedupe_add_exclude_path(zdedupe_ctx*, const char*);
void zdedupe_cancel(zdedupe_ctx*);
int zdedupe_run_to_file(zdedupe_ctx*, const char*);
const char* zdedupe_run_sync(zdedupe_ctx*);
void zdedupe_get_progress(const zdedupe_ctx*, zdedupe_progress*);
size_t zdedupe_get_current_path(const zdedupe_ctx*, char*, size_t, bool*);
zdedupe_results* zdedupe_results_open(const char* store_path, const char* roots_json);
void zdedupe_results_close(zdedupe_results*);
const char* zdedupe_results_last_error(const zdedupe_results*);
const char* zdedupe_results_overview(zdedupe_results*);
int zdedupe_results_export(zdedupe_results*, const char* format, const char* path);

#define NPHASES 8
static const char* names[NPHASES] = {"idle", "walk", "size-group", "quick-hash", "full-hash", "analyze", "write", "done"};

static double log_every;    // -L SECS: periodic progress line
static double cancel_stall; // -C SECS: cancel once one item has been stuck that long
static int walk_only;
static volatile int running = 1;
static zdedupe_ctx* ctx;
static double t0, cancel_sent;
// Per phase: when it was first entered (wall, and process CPU) and its item count.
static double ph_start[NPHASES], ph_cpu[NPHASES];
static uint64_t ph_items[NPHASES];
static int seen[NPHASES];

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

// User + system CPU seconds of the whole process, every thread included.
static double cpu_now(void) {
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

static size_t footprint(void) {
#ifdef __APPLE__
  task_vm_info_data_t i;
  mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &n) != KERN_SUCCESS) return 0;
  return i.phys_footprint;
#else
  long pages = 0, rss = 0;
  FILE* f = fopen("/proc/self/statm", "r");
  if (f) {
    if (fscanf(f, "%ld %ld", &pages, &rss) != 2) rss = 0;
    fclose(f);
  }
  return (size_t)rss * (size_t)sysconf(_SC_PAGESIZE);
#endif
}

static void* poll(void* unused) {
  (void)unused;
  int last = -1;
  double next_log = log_every, last_t = 0;
  uint64_t last_found = 0, last_done = 0;
  while (running) {
    zdedupe_progress p;
    zdedupe_get_progress(ctx, &p);
    if (log_every > 0 && now() - t0 >= next_log) {
      double t = now() - t0;
      char cur[512];
      bool tail = false;
      size_t w = zdedupe_get_current_path(ctx, cur, sizeof cur - 1, &tail);
      cur[w] = 0;
      fprintf(stderr, "[%7.0fs] %-10s found=%llu (+%.0f/s) done=%llu/%llu (+%.0f/s) bytes=%.2f/%.2fGB stalled=%llums footprint=%.0fMB cur=%s%s\n",
              t, names[p.phase < NPHASES ? p.phase : 0], (unsigned long long)p.files_found, (p.files_found - last_found) / (t - last_t),
              (unsigned long long)p.done, (unsigned long long)p.total, (p.done >= last_done ? (p.done - last_done) : 0) / (t - last_t),
              p.bytes_done / 1e9, p.bytes_total / 1e9, (unsigned long long)p.stalled_ms, footprint() / 1e6, tail ? "..." : "", w ? cur : "-");
      last_found = p.files_found;
      last_done = p.done;
      last_t = t;
      next_log += log_every;
    }
    int ph = p.phase < NPHASES ? (int)p.phase : 0;
    if (ph != last) {
      if (!seen[ph]) {
        seen[ph] = 1;
        ph_start[ph] = now() - t0;
        ph_cpu[ph] = cpu_now();
      }
      fprintf(stderr, "[%8.2fs] -> %s (found=%llu total=%llu)\n", now() - t0, names[ph], (unsigned long long)p.files_found, (unsigned long long)p.total);
      last = ph;
    }
    if (walk_only && ph > 1) zdedupe_cancel(ctx);
    if (cancel_stall > 0 && p.stalled_ms >= cancel_stall * 1000 && !cancel_sent) {
      cancel_sent = now() - t0;
      fprintf(stderr, "[%8.2fs] stalled %llu ms -> cancel\n", cancel_sent, (unsigned long long)p.stalled_ms);
      zdedupe_cancel(ctx);
    }
    ph_items[ph] = ph == 1 ? p.files_found : p.total;
    // 1 ms: phase boundaries to the millisecond, at a CPU cost the totals do not notice.
    usleep(1000);
  }
  return 0;
}

// The scan roots as a JSON array, for zdedupe_results_open.
static char* roots_json(char** paths, int n) {
  size_t cap = 3;
  for (int i = 0; i < n; i++) cap += 2 * strlen(paths[i]) + 4;
  char* out = malloc(cap);
  size_t w = 0;
  out[w++] = '[';
  for (int i = 0; i < n; i++) {
    if (i) out[w++] = ',';
    out[w++] = '"';
    for (const char* s = paths[i]; *s; s++) {
      if (*s == '"' || *s == '\\') out[w++] = '\\';
      out[w++] = *s;
    }
    out[w++] = '"';
  }
  out[w++] = ']';
  out[w] = 0;
  return out;
}

int main(int argc, char** argv) {
  int mode = 0, c, nx = 0;
  bool dirs = false, defx = false, credx = false, hidden = false;
  unsigned thr = 0;
  const char* out = "/tmp/zd-store.bin";
  const char *json_out = NULL, *export_out = NULL;
  const char* xs[32];
  while ((c = getopt(argc, argv, "m:dxcHWj:o:L:X:C:J:E:")) != -1) {
    switch (c) {
      case 'm': mode = atoi(optarg); break;
      case 'd': dirs = true; break;
      case 'x': defx = true; break;
      case 'c': credx = true; break;
      case 'H': hidden = true; break;
      case 'W': walk_only = 1; break;
      case 'j': thr = atoi(optarg); break;
      case 'o': out = optarg; break;
      case 'L': log_every = atof(optarg); break;
      case 'C': cancel_stall = atof(optarg); break;
      case 'X': if (nx < 32) xs[nx++] = optarg; break;
      case 'J': json_out = optarg; break;
      case 'E': export_out = optarg; break;
      default: return 2;
    }
  }
  ctx = zdedupe_init();
  zdedupe_set_mode(ctx, mode);
  zdedupe_set_analyze_dirs(ctx, dirs);
  zdedupe_use_default_excludes(ctx, defx);
  zdedupe_use_credential_excludes(ctx, credx);
  zdedupe_set_include_hidden(ctx, hidden);
  if (thr) zdedupe_set_threads(ctx, thr);
  for (int i = 0; i < nx; i++) zdedupe_add_exclude_path(ctx, xs[i]);
  for (int i = optind; i < argc; i++)
    if (zdedupe_add_path(ctx, argv[i]) != 0) {
      fprintf(stderr, "bad path %s\n", argv[i]);
      return 2;
    }

  pthread_t th;
  t0 = now();
  double cpu0 = cpu_now();
  pthread_create(&th, 0, poll, 0);
  int rc;
  const char* report = NULL;
  if (mode == 1) {
    // A folder comparison has no result store; its answer is the report.
    report = zdedupe_run_sync(ctx);
    rc = report ? 0 : 1;
  } else {
    rc = zdedupe_run_to_file(ctx, out);
  }
  double total = now() - t0;
  double cpu_total = cpu_now() - cpu0;
  running = 0;
  pthread_join(th, 0);

  printf("rc=%d total=%.3fs cpu=%.3fs cores=%.2f%s\n", rc, total, cpu_total, total > 0 ? cpu_total / total : 0, cancel_sent > 0 ? " (cancelled)" : "");
  if (cancel_sent > 0) printf("cancel returned %.3fs after it was sent\n", total - cancel_sent);

  // Phases in the order they began; each lasts until the next one begins.
  int order[NPHASES], n = 0;
  for (int ph = 1; ph < NPHASES; ph++)
    if (seen[ph]) order[n++] = ph;
  for (int a = 1; a < n; a++)
    for (int b = a; b > 0 && ph_start[order[b]] < ph_start[order[b - 1]]; b--) {
      int t = order[b];
      order[b] = order[b - 1];
      order[b - 1] = t;
    }
  double end_wall[NPHASES], end_cpu[NPHASES];
  for (int i = 0; i < n; i++) {
    end_wall[i] = i + 1 < n ? ph_start[order[i + 1]] : total;
    end_cpu[i] = i + 1 < n ? ph_cpu[order[i + 1]] : cpu0 + cpu_total;
    if (order[i] == 7) continue;
    double wall = end_wall[i] - ph_start[order[i]], cpu = end_cpu[i] - ph_cpu[order[i]];
    printf("  %-10s %8.3fs  cores=%5.2f  items=%llu\n", names[order[i]], wall, wall > 0 ? cpu / wall : 0, (unsigned long long)ph_items[order[i]]);
  }

  char* overview = NULL;
  zdedupe_results* results = NULL;
  if (rc == 0 && mode != 1 && (json_out || export_out)) {
    char* roots = roots_json(argv + optind, argc - optind);
    results = zdedupe_results_open(out, roots);
    free(roots);
    if (!results) fprintf(stderr, "results_open failed\n");
    else {
      // Owned by the session and valid only until its next call: copied before the export.
      const char* o = zdedupe_results_overview(results);
      overview = o ? strdup(o) : NULL;
    }
    if (results && export_out && mode == 0 && zdedupe_results_export(results, "csv", export_out) != 0)
      fprintf(stderr, "export failed: %s\n", zdedupe_results_last_error(results));
  }
  if (rc == 0 && mode == 1 && export_out) {
    FILE* f = fopen(export_out, "w");
    if (f) {
      fputs(report, f);
      fclose(f);
    }
  }

  if (json_out) {
    FILE* f = fopen(json_out, "w");
    if (!f) {
      fprintf(stderr, "cannot write %s\n", json_out);
      return 1;
    }
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
#ifdef __APPLE__
    double maxrss_mb = u.ru_maxrss / 1e6; // bytes on macOS
#else
    double maxrss_mb = u.ru_maxrss / 1e3; // kilobytes on Linux
#endif
    fprintf(f, "{\"rc\":%d,\"cancelled\":%s,\"wall_s\":%.6f,\"cpu_s\":%.6f,\"maxrss_mb\":%.1f,\"phases\":[",
            rc, cancel_sent > 0 ? "true" : "false", total, cpu_total, maxrss_mb);
    int first = 1;
    for (int i = 0; i < n; i++) {
      if (order[i] == 7) continue;
      fprintf(f, "%s{\"name\":\"%s\",\"start_s\":%.6f,\"wall_s\":%.6f,\"cpu_s\":%.6f,\"items\":%llu}", first ? "" : ",",
              names[order[i]], ph_start[order[i]], end_wall[i] - ph_start[order[i]], end_cpu[i] - ph_cpu[order[i]],
              (unsigned long long)ph_items[order[i]]);
      first = 0;
    }
    fprintf(f, "],\"overview\":%s}\n", overview ? overview : "null");
    fclose(f);
  }
  free(overview);
  if (results) zdedupe_results_close(results);
  zdedupe_free(ctx);
  return rc;
}
