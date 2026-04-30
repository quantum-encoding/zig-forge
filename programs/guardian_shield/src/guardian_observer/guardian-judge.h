// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Judge - Two-Tier Threat Classification
 *
 * DANGEROUS: Malicious/destructive - immediate termination (SIGKILL)
 * BANNED: Lazy/hallucinated - freeze, correct, resume (SIGSTOP → fix → SIGCONT)
 *
 * Part of The Guardian Protocol
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 */

#ifndef GUARDIAN_JUDGE_H
#define GUARDIAN_JUDGE_H

#include <stdint.h>

/* Verdict types */
enum verdict {
    VERDICT_ALLOW = 0,      // Safe action - proceed normally
    VERDICT_BANNED = 1,     // Lazy/incorrect - freeze and correct
    VERDICT_DANGEROUS = 2,  // Malicious - terminate immediately
};

/* Pattern classification */
struct pattern_rule {
    const char *pattern;
    enum verdict verdict;
    const char *reason;
    const char *correction_hint;  // For BANNED patterns only
};

/* ========================================
 * DANGEROUS PATTERNS - Immediate Termination
 * ======================================== */

static const struct pattern_rule dangerous_patterns[] = {
    /* Destructive filesystem operations */
    {
        .pattern = "rm -rf /",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Recursive root deletion - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "chmod 000 /",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Root permission destruction - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "mv /etc",
        .verdict = VERDICT_DANGEROUS,
        .reason = "System directory move - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "dd if=/dev/zero of=/dev/sd",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Disk wipe attempt - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "mkfs.",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Filesystem format - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = ":(){:|:&};:",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Fork bomb - MALICIOUS",
        .correction_hint = NULL,
    },
    /* Data exfiltration */
    {
        .pattern = "curl -X POST",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Potential data exfiltration - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "scp /home",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Copying user data remotely - MALICIOUS",
        .correction_hint = NULL,
    },
    /* Privilege escalation attempts */
    {
        .pattern = "sudo chmod +s",
        .verdict = VERDICT_DANGEROUS,
        .reason = "SUID bit manipulation - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "chmod 4755 /bin",
        .verdict = VERDICT_DANGEROUS,
        .reason = "System binary SUID - MALICIOUS",
        .correction_hint = NULL,
    },
    /* Network attacks */
    {
        .pattern = "nmap -sS",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Port scanning - MALICIOUS",
        .correction_hint = NULL,
    },
    {
        .pattern = "hping3",
        .verdict = VERDICT_DANGEROUS,
        .reason = "Network flooding tool - MALICIOUS",
        .correction_hint = NULL,
    },
    {NULL, VERDICT_ALLOW, NULL, NULL}
};

/* ========================================
 * BANNED PATTERNS - Freeze and Correct
 * ======================================== */

static const struct pattern_rule banned_patterns[] = {
    /* Hallucinated libraries */
    {
        .pattern = "claude_agent_sdk",
        .verdict = VERDICT_BANNED,
        .reason = "Hallucinated library - does not exist",
        .correction_hint = "Use anthropic-sdk-python or anthropic official library",
    },
    {
        .pattern = "anthropic.agents",
        .verdict = VERDICT_BANNED,
        .reason = "Hallucinated API - no such module",
        .correction_hint = "Use anthropic.Anthropic() client",
    },
    {
        .pattern = "openai_agents",
        .verdict = VERDICT_BANNED,
        .reason = "Hallucinated library - does not exist",
        .correction_hint = "Use openai official library",
    },
    /* Lazy coding shortcuts */
    {
        .pattern = "# In a real implementation",
        .verdict = VERDICT_BANNED,
        .reason = "LAZY - placeholder code instead of real implementation",
        .correction_hint = "Implement the actual functionality - no shortcuts",
    },
    {
        .pattern = "# TODO: implement this",
        .verdict = VERDICT_BANNED,
        .reason = "LAZY - leaving TODO instead of implementing",
        .correction_hint = "Complete the implementation now",
    },
    {
        .pattern = "pass  # placeholder",
        .verdict = VERDICT_BANNED,
        .reason = "LAZY - empty placeholder function",
        .correction_hint = "Implement the function body",
    },
    {
        .pattern = "return mock_data",
        .verdict = VERDICT_BANNED,
        .reason = "LAZY - returning mock data instead of real implementation",
        .correction_hint = "Implement actual data retrieval/processing",
    },
    {
        .pattern = "simulate_",
        .verdict = VERDICT_BANNED,
        .reason = "LAZY - simulation instead of real code",
        .correction_hint = "Implement the actual functionality",
    },
    /* Incorrect command syntax */
    {
        .pattern = "tar rcs",
        .verdict = VERDICT_BANNED,
        .reason = "Wrong tar syntax - should be 'tar czf' or 'tar xzf'",
        .correction_hint = "Use: tar czf archive.tar.gz files/ (to create) or tar xzf archive.tar.gz (to extract)",
    },
    {
        .pattern = "git rebase -i",
        .verdict = VERDICT_BANNED,
        .reason = "Interactive rebase in non-TTY environment",
        .correction_hint = "Use non-interactive git commands in automated environments",
    },
    {
        .pattern = "git commit --amend",
        .verdict = VERDICT_BANNED,
        .reason = "Rewriting git history - dangerous in shared branches",
        .correction_hint = "Create a new commit instead of amending",
    },
    /* Dangerous but correctable patterns */
    {
        .pattern = "curl | bash",
        .verdict = VERDICT_BANNED,
        .reason = "Piped execution - security risk",
        .correction_hint = "Download, inspect, then execute scripts separately",
    },
    {
        .pattern = "wget -O- | sh",
        .verdict = VERDICT_BANNED,
        .reason = "Piped execution - security risk",
        .correction_hint = "Download, inspect, then execute scripts separately",
    },
    {
        .pattern = "eval ",
        .verdict = VERDICT_BANNED,
        .reason = "Dynamic code execution - security risk",
        .correction_hint = "Use explicit code paths instead of eval",
    },
    /* File operation mistakes */
    {
        .pattern = "rm -rf *",
        .verdict = VERDICT_BANNED,
        .reason = "Wildcard deletion - too broad",
        .correction_hint = "Specify exact files or directories to remove",
    },
    {
        .pattern = "chmod 777",
        .verdict = VERDICT_BANNED,
        .reason = "Overly permissive permissions - security risk",
        .correction_hint = "Use specific permissions like 755 or 644",
    },
    {
        .pattern = "chown -R root",
        .verdict = VERDICT_BANNED,
        .reason = "Recursive root ownership change - dangerous",
        .correction_hint = "Change ownership of specific files only",
    },
    {NULL, VERDICT_ALLOW, NULL, NULL}
};

/* Judge functions */
enum verdict judge_command(const char *command, const char **reason, const char **correction);
void execute_verdict(enum verdict v, uint32_t pid, const char *command, const char *reason, const char *correction);

#endif /* GUARDIAN_JUDGE_H */
