/*
 * Native stand-in agent for tests/zterm_runner_qa.py on macOS.
 *
 * The runner decides a pane holds an agent by its foreground process's name.
 * On Darwin that name (proc_name) is the executable's file name, so the
 * Python stand-in next to this file reads as its interpreter ("Python"),
 * never "claude"; the harness compiles this file to a binary named `claude`
 * instead. It behaves exactly like the Python one: raw mode, bracketed paste
 * on, every byte received appended to the log named by argv[1] and echoed
 * with the paste brackets removed and CR shown as CR LF.
 */
#include <fcntl.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static void put(const char *b, size_t n) {
    while (n > 0) {
        ssize_t w = write(1, b, n);
        if (w <= 0) return;
        b += w;
        n -= (size_t)w;
    }
}

static void echo(const char *b, size_t n) {
    size_t i = 0;
    while (i < n) {
        if (n - i >= 6 && (memcmp(b + i, "\x1b[200~", 6) == 0 || memcmp(b + i, "\x1b[201~", 6) == 0)) {
            i += 6;
        } else if (b[i] == '\r') {
            put("\r\n", 2);
            i += 1;
        } else {
            put(b + i, 1);
            i += 1;
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    struct termios t;
    if (tcgetattr(0, &t) == 0) {
        cfmakeraw(&t);
        tcsetattr(0, TCSAFLUSH, &t);
    }
    int log = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log < 0) return 1;
    const char ready[] = "\x1b[?2004hfake-claude ready> ";
    put(ready, sizeof ready - 1);
    char buf[65536];
    for (;;) {
        ssize_t n = read(0, buf, sizeof buf);
        if (n <= 0) break;
        if (write(log, buf, (size_t)n) != n) return 1;
        echo(buf, (size_t)n);
    }
    return 0;
}
