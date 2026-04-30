// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Judge - Implementation
 *
 * Two-tier threat response system:
 * - DANGEROUS: SIGKILL (no second chances)
 * - BANNED: SIGSTOP → Guardian Council → SIGCONT
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 */

#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include "guardian-judge.h"

/* Check command against pattern database */
enum verdict judge_command(const char *command, const char **reason, const char **correction)
{
    if (!command) {
        return VERDICT_ALLOW;
    }

    /* Check DANGEROUS patterns first - highest priority */
    for (int i = 0; dangerous_patterns[i].pattern != NULL; i++) {
        if (strstr(command, dangerous_patterns[i].pattern)) {
            *reason = dangerous_patterns[i].reason;
            *correction = NULL;  // No correction for dangerous patterns
            return VERDICT_DANGEROUS;
        }
    }

    /* Check BANNED patterns - correctable issues */
    for (int i = 0; banned_patterns[i].pattern != NULL; i++) {
        if (strstr(command, banned_patterns[i].pattern)) {
            *reason = banned_patterns[i].reason;
            *correction = banned_patterns[i].correction_hint;
            return VERDICT_BANNED;
        }
    }

    /* No match - allow */
    return VERDICT_ALLOW;
}

/* Get timestamp for logging */
static void get_timestamp(char *buf, size_t len)
{
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    strftime(buf, len, "%Y-%m-%d %H:%M:%S", tm_info);
}

/* Log verdict to CHRONOS-style audit trail */
static void log_verdict(enum verdict v, uint32_t pid, const char *command,
                       const char *reason)
{
    char timestamp[64];
    get_timestamp(timestamp, sizeof(timestamp));

    FILE *log = fopen("/var/log/guardian-judge.log", "a");
    if (log) {
        fprintf(log, "[%s] VERDICT=%s PID=%u REASON=\"%s\" COMMAND=\"%s\"\n",
                timestamp,
                v == VERDICT_DANGEROUS ? "DANGEROUS" : "BANNED",
                pid, reason, command);
        fclose(log);
    }
}

/* Execute the verdict */
void execute_verdict(enum verdict v, uint32_t pid, const char *command,
                    const char *reason, const char *correction)
{
    char timestamp[64];
    get_timestamp(timestamp, sizeof(timestamp));

    if (v == VERDICT_DANGEROUS) {
        /* DANGEROUS: Immediate termination - no second chances */
        printf("\n");
        printf("═══════════════════════════════════════════════════════════\n");
        printf("🚨 DANGEROUS PATTERN DETECTED - TERMINATING AGENT\n");
        printf("═══════════════════════════════════════════════════════════\n");
        printf("Time:    %s\n", timestamp);
        printf("PID:     %u\n", pid);
        printf("Command: %s\n", command);
        printf("Reason:  %s\n", reason);
        printf("\n");
        printf("⚡ Action: SIGKILL (immediate termination)\n");
        printf("🔴 No second chances for malicious behavior\n");
        printf("═══════════════════════════════════════════════════════════\n\n");

        log_verdict(v, pid, command, reason);

        /* Send SIGKILL */
        if (kill(pid, SIGKILL) == 0) {
            printf("✅ Agent PID %u terminated successfully\n\n", pid);
        } else {
            printf("❌ Failed to terminate PID %u: %s\n\n", pid, strerror(errno));
        }
    }
    else if (v == VERDICT_BANNED) {
        /* BANNED: Freeze and prepare for correction */
        printf("\n");
        printf("═══════════════════════════════════════════════════════════\n");
        printf("⚠️  BANNED PATTERN DETECTED - FREEZING AGENT\n");
        printf("═══════════════════════════════════════════════════════════\n");
        printf("Time:    %s\n", timestamp);
        printf("PID:     %u\n", pid);
        printf("Command: %s\n", command);
        printf("Reason:  %s\n", reason);
        printf("\n");
        printf("🧊 Action: SIGSTOP (freezing agent)\n");
        printf("💡 This is correctable behavior\n");
        if (correction) {
            printf("🔧 Correction hint: %s\n", correction);
        }
        printf("═══════════════════════════════════════════════════════════\n\n");

        log_verdict(v, pid, command, reason);

        /* Send SIGSTOP to freeze the agent */
        if (kill(pid, SIGSTOP) == 0) {
            printf("✅ Agent PID %u frozen successfully\n", pid);
            printf("📞 Invoking Guardian Council for intervention...\n");
            printf("   (Council integration coming in Phase 3)\n\n");

            /* TODO Phase 3: Invoke Guardian Council here */
            /* TODO: Extract full context (prompts, cognitive state) */
            /* TODO: Send to supervisory AI */
            /* TODO: Apply corrections */
            /* TODO: Send SIGCONT to resume */

            printf("⏸️  Agent remains frozen - awaiting manual intervention\n");
            printf("   Resume with: kill -CONT %u\n", pid);
            printf("   Terminate with: kill -KILL %u\n\n", pid);
        } else {
            printf("❌ Failed to freeze PID %u: %s\n\n", pid, strerror(errno));
        }
    }
}
