// c_bugs.c — Real bugs that C allows, demonstrated safely
//
// These are the ACTUAL bug patterns from the disasters in our scenario list.
// Compiled with zig cc as part of the build. Each function demonstrates
// a bug class that Zig prevents structurally.
//
// IMPORTANT: These demos are designed to show the bug pattern without
// triggering actual undefined behavior (where possible). The point is
// to show what C ALLOWS that Zig PREVENTS.

#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

// ====================================================================
// Result struct for each demo
// ====================================================================
typedef struct {
    const char *name;
    const char *bug_class;
    int         triggered;     // 1 = bug would have fired in real code
    int         c_catches_it;  // 0 = C does NOT catch this
    const char *what_happens;
} DemoResult;

static DemoResult results[16];
static int result_count = 0;

static void add_result(const char *name, const char *bug_class,
                       int triggered, int caught, const char *what) {
    if (result_count < 16) {
        results[result_count].name = name;
        results[result_count].bug_class = bug_class;
        results[result_count].triggered = triggered;
        results[result_count].c_catches_it = caught;
        results[result_count].what_happens = what;
        result_count++;
    }
}

// ====================================================================
// 1. ARIANE 5: Integer overflow / silent truncation
// ====================================================================
void demo_ariane_overflow(void) {
    double horizontal_bias = 32768.5; // The exact value from Flight 501

    // C allows casting out-of-range double to int16_t — UB in the standard.
    // Most compilers silently truncate/wrap. zig cc catches it with UBSan.
    // We demonstrate the bug without triggering UB:
    int fits_in_i16 = (horizontal_bias >= -32768.0 && horizontal_bias <= 32767.0);
    // Answer: NO. 32768.5 > 32767. The cast is invalid.

    // In real Ariane 5: the Ada runtime raised OPERAND_ERROR,
    // but the handler was disabled "for performance". SRI shut down.
    // In C: no error at all. Silent wrong value.

    add_result("Ariane 5 Flight 501",
               "Integer overflow (f64 -> i16)",
               !fits_in_i16, 0,
               "C allows (int16_t)32768.5 — undefined behavior. No error, no warning.");
}

// ====================================================================
// 2. MCO: Implicit unit confusion (types are just doubles)
// ====================================================================
void demo_mco_units(void) {
    double thrust_lbf = 4.45;  // Pound-force (Lockheed Martin sent this)
    double thrust_n = thrust_lbf; // "Converting" by assignment — WRONG

    // C: both are just "double". No type distinction whatsoever.
    // The 4.45x error accumulated over 9 months of navigation.
    double correction = thrust_n * 1.0; // Should have been * 4.44822

    int is_wrong = (correction < 19.0); // Should be ~19.77 N, got 4.45

    add_result("Mars Climate Orbiter",
               "Unit mismatch (lbf vs N)",
               is_wrong, 0,
               "C treats pound-force and newtons as the same type: double. 4.45x error.");
    (void)correction;
}

// ====================================================================
// 3. HEARTBLEED: Buffer over-read (memcpy with attacker-controlled length)
// ====================================================================
void demo_heartbleed(void) {
    char payload[1] = {'X'};       // Actual payload: 1 byte
    int claimed_length = 64;        // Attacker claims 64 bytes
    char response[128];
    memset(response, 0, sizeof(response));

    // This is EXACTLY what OpenSSL did in CVE-2014-0160:
    // memcpy with attacker-controlled length, reading past the buffer.
    // We use a larger source to avoid actual segfault in this demo.
    char leak_source[128];
    memset(leak_source, 'S', sizeof(leak_source)); // "Secret" data
    leak_source[0] = payload[0]; // First byte is real payload

    memcpy(response, leak_source, claimed_length);
    // C happily copied 64 bytes when payload was only 1 byte.
    // In real Heartbleed: private keys, passwords, session tokens leaked.

    int leaked_extra = (response[1] == 'S'); // Read "secret" data

    add_result("OpenSSL Heartbleed",
               "Buffer over-read (memcpy)",
               leaked_extra, 0,
               "C memcpy reads 64 bytes from 1-byte payload. Leaks adjacent memory.");
}

// ====================================================================
// 4. CROWDSTRIKE: Out-of-bounds array access
// ====================================================================
void demo_crowdstrike(void) {
    void *config_values[20];
    memset(config_values, 0, sizeof(config_values));

    int index = 20; // One past the end (Channel File 291 bug)

    // In C: this compiles and runs. Reads garbage from stack.
    // In the real incident: garbage pointer dereferenced in kernel → BSOD
    int oob = (index >= 20); // Would be OOB

    add_result("CrowdStrike Falcon",
               "Array out-of-bounds",
               oob, 0,
               "C allows array[20] on 20-element array. Reads garbage, crashed 8.5M machines.");
}

// ====================================================================
// 5. MORRIS WORM: gets() buffer overflow
// ====================================================================
void demo_morris(void) {
    // gets() was so dangerous it was REMOVED from C11.
    // But strcpy without bounds checking is still everywhere.
    char buffer[16];
    const char *input = "This is way longer than 16 bytes and would overflow the buffer";

    // Safe demo: show that strcpy WOULD overflow
    int would_overflow = (strlen(input) > sizeof(buffer));

    // In real code: strcpy(buffer, input) would smash the stack
    // First major internet worm exploited exactly this.

    add_result("Morris Worm (fingerd)",
               "Buffer overflow (strcpy/gets)",
               would_overflow, 0,
               "C strcpy/gets have NO length limit. Stack smashed, return address overwritten.");
    (void)buffer;
}

// ====================================================================
// 6. TOYOTA: Stack corruption from overflow
// ====================================================================
static int toyota_counter = 0;
void demo_toyota_recursive(int depth) {
    char frame[64]; // Simulate large stack frame
    memset(frame, 0, sizeof(frame));
    toyota_counter++;
    if (depth > 0) {
        demo_toyota_recursive(depth - 1);
    }
}

void demo_toyota(void) {
    toyota_counter = 0;
    // In real Toyota code: recursion with 10,000+ globals, tiny task stack
    // Stack overflow silently corrupts adjacent memory (throttle variable)
    demo_toyota_recursive(10); // Safe depth for demo

    // The bug: C has no stack overflow detection.
    // When stack overflows, it silently overwrites adjacent memory.
    add_result("Toyota Unintended Acceleration",
               "Stack overflow -> memory corruption",
               1, 0,
               "C has no stack overflow detection. Overflow silently corrupts adjacent memory.");
}

// ====================================================================
// 7. Y2K: Integer wraparound
// ====================================================================
void demo_y2k(void) {
    unsigned char year = 99;
    year++; // Wraps to 0 in C — silent wraparound, no error

    int wrapped = (year == 0); // Year 2000 → year 0

    add_result("Y2K Bug",
               "Integer wraparound (u8)",
               wrapped, 0,
               "C unsigned overflow wraps silently. 99+1=0, not 100. No error.");
}

// ====================================================================
// 8. LOG4SHELL: String handling (simplified demo)
// ====================================================================
void demo_log4shell(void) {
    // In Java: log.info(userInput) interprets ${jndi:ldap://...} as code
    // In C: printf(userInput) with format specifiers is similar
    const char *user_input = "%s%s%s%s%s"; // Format string attack

    // printf(user_input) would read stack memory (format string vulnerability)
    // This is the C equivalent of Log4Shell's string interpretation bug
    int vulnerable = 1; // C's printf WOULD interpret format specifiers

    add_result("Log4Shell (Log4j) [C equivalent: printf]",
               "Format string / code injection",
               vulnerable, 0,
               "C printf(user_input) interprets format specifiers. Reads/writes stack.");
}

// ====================================================================
// 9. CLOUDBLEED: Pointer arithmetic past buffer
// ====================================================================
void demo_cloudbleed(void) {
    const char *buffer = "no closing bracket here";
    const char *p = buffer;
    const char *end = buffer + strlen(buffer);

    // In buggy code: while (*p != '>') p++; — no bounds check
    // Pointer walks past buffer if '>' is never found
    int would_overread = 1;
    while (p < end) {
        if (*p == '>') {
            would_overread = 0;
            break;
        }
        p++;
    }
    // In real Cloudbleed: no 'end' check. Pointer walked into other
    // customers' HTTP data. Leaked passwords, cookies, auth tokens.

    add_result("Cloudflare Cloudbleed",
               "Pointer arithmetic past buffer",
               would_overread, 0,
               "C allows unbounded pointer increment. Reads adjacent memory on missing delimiter.");
}

// ====================================================================
// 10. QANTAS FLIGHT 72: Use of corrupted data
// ====================================================================
void demo_qantas(void) {
    float sensor_data[128];
    for (int i = 0; i < 128; i++) sensor_data[i] = 2.5f;

    int corrupted_index = 256; // Out of bounds

    // In C: sensor_data[256] reads garbage from stack/heap
    // Real ADIRU returned 50.625 degrees (impossible AoA value)
    int oob = (corrupted_index >= 128);

    add_result("Qantas Flight 72",
               "Out-of-bounds memory read",
               oob, 0,
               "C array[256] on 128-element array reads garbage. Autopilot got 50.625 deg AoA.");
}

// ====================================================================
// SUMMARY: Print all results
// ====================================================================
int get_result_count(void) {
    return result_count;
}

DemoResult *get_result(int index) {
    if (index >= 0 && index < result_count) {
        return &results[index];
    }
    return NULL;
}

const char *get_result_name(int index) {
    if (index >= 0 && index < result_count) return results[index].name;
    return "";
}

const char *get_result_bug_class(int index) {
    if (index >= 0 && index < result_count) return results[index].bug_class;
    return "";
}

int get_result_triggered(int index) {
    if (index >= 0 && index < result_count) return results[index].triggered;
    return 0;
}

int get_result_caught(int index) {
    if (index >= 0 && index < result_count) return results[index].c_catches_it;
    return 0;
}

const char *get_result_what(int index) {
    if (index >= 0 && index < result_count) return results[index].what_happens;
    return "";
}

void run_all_demos(void) {
    result_count = 0;
    demo_ariane_overflow();
    demo_mco_units();
    demo_heartbleed();
    demo_crowdstrike();
    demo_morris();
    demo_toyota();
    demo_y2k();
    demo_log4shell();
    demo_cloudbleed();
    demo_qantas();
}
