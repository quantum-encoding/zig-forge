// Test program to simulate Claude Code cognitive state output
#include <stdio.h>
#include <unistd.h>
#include <string.h>

int main() {
    // Simulate what we think Claude Code outputs
    const char *test_patterns[] = {
        "::claude-code::Thinking::\n",
        "::claude-code::Executing::\n",
        "::claude-code::Reading::\n",
        "::claude-code::Writing::\n",
    };

    printf("Testing cognitive patterns...\n");

    for (int i = 0; i < 4; i++) {
        printf("Pattern %d: %s", i+1, test_patterns[i]);
        fflush(stdout);
        sleep(1);
    }

    printf("Test complete\n");
    return 0;
}
