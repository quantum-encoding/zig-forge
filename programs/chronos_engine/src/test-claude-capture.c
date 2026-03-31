#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <sys/reg.h>  // For ORIG_RAX, etc.
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define WRITE_SYSCALL 1  // Syscall number for write on x86_64

void print_buffer(pid_t child, unsigned long addr, unsigned long len) {
    unsigned long *buf = malloc(len + sizeof(unsigned long));  // Extra space for safety
    if (!buf) {
        perror("malloc");
        return;
    }

    for (unsigned long i = 0; i < len; i += sizeof(unsigned long)) {
        long data = ptrace(PTRACE_PEEKDATA, child, addr + i, NULL);
        if (data == -1 && errno != 0) {
            perror("ptrace PEEKDATA");
            free(buf);
            return;
        }
        memcpy((char *)buf + i, &data, sizeof(long));
    }

    // Print as string, assuming null-terminated or printable
    fwrite(buf, 1, len, stdout);
    printf("\n");  // Newline for clarity

    free(buf);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <program> [args...]\n", argv[0]);
        fprintf(stderr, "Example: %s claude-code --help\n", argv[0]);
        exit(1);
    }

    pid_t child = fork();
    if (child == 0) {
        // Child process
        ptrace(PTRACE_TRACEME, 0, NULL, NULL);
        execvp(argv[1], &argv[1]);
        perror("execvp");
        exit(1);
    } else if (child > 0) {
        // Parent process
        int status;
        waitpid(child, &status, 0);

        if (WIFEXITED(status)) {
            return 0;  // Child exited immediately
        }

        // Enable syscall tracing
        ptrace(PTRACE_SETOPTIONS, child, 0, PTRACE_O_TRACESYSGOOD);

        while (1) {
            // Enter syscall
            ptrace(PTRACE_SYSCALL, child, NULL, NULL);
            waitpid(child, &status, 0);

            if (WIFEXITED(status)) {
                printf("Child exited with status %d\n", WEXITSTATUS(status));
                break;
            }

            struct user_regs_struct regs;
            ptrace(PTRACE_GETREGS, child, NULL, &regs);

            // Check if it's write syscall
            if (regs.orig_rax == WRITE_SYSCALL) {
                unsigned long fd = regs.rdi;
                unsigned long buf_addr = regs.rsi;
                unsigned long count = regs.rdx;

                // Only capture stdout (1) and stderr (2)
                if (fd == 1 || fd == 2) {
                    printf("Intercepted write to fd=%lu, len=%lu: ", fd, count);
                    print_buffer(child, buf_addr, count);
                }
            }
        }
    } else {
        perror("fork");
        exit(1);
    }

    return 0;
}
