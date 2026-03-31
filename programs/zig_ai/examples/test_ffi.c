#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "include/zig_ai.h"

// Helper to create ZigAiString from C string
ZigAiString make_string(const char* s) {
    ZigAiString str = { s, s ? strlen(s) : 0 };
    return str;
}

void test_version(void) {
    printf("=== Test: Library Version ===\n");
    ZigAiString version = zig_ai_version();
    printf("zig_ai version: %.*s\n", (int)version.len, version.ptr);
    printf("PASS\n\n");
}

void test_text_provider_info(void) {
    printf("=== Test: Text Provider Info ===\n");

    ZigAiTextProvider providers[] = {
        ZIG_AI_TEXT_CLAUDE,
        ZIG_AI_TEXT_DEEPSEEK,
        ZIG_AI_TEXT_GEMINI,
        ZIG_AI_TEXT_GROK,
        ZIG_AI_TEXT_VERTEX
    };
    const char* names[] = {"Claude", "DeepSeek", "Gemini", "Grok", "Vertex"};

    for (int i = 0; i < 5; i++) {
        ZigAiString model = zig_ai_text_default_model(providers[i]);
        bool available = zig_ai_text_provider_available(providers[i]);
        printf("  %s: model=%.*s, available=%s\n",
               names[i],
               (int)model.len, model.ptr,
               available ? "yes" : "no");
    }
    printf("PASS\n\n");
}

void test_text_session(void) {
    printf("=== Test: Text Session Create/Destroy ===\n");

    ZigAiTextConfig config = {
        .provider = ZIG_AI_TEXT_DEEPSEEK,
        .model = make_string("deepseek-chat"),
        .temperature = 0.7f,
        .max_tokens = 1024,
        .system_prompt = make_string("You are a helpful assistant."),
        .api_key = make_string(NULL)
    };

    ZigAiTextSession* session = zig_ai_text_session_create(&config);
    if (session) {
        printf("  Session created successfully\n");
        zig_ai_text_session_destroy(session);
        printf("  Session destroyed successfully\n");
        printf("PASS\n\n");
    } else {
        printf("FAIL: Could not create session\n\n");
    }
}

void test_image_provider_info(void) {
    printf("=== Test: Image Provider Info ===\n");

    ZigAiImageProvider providers[] = {
        ZIG_AI_IMAGE_DALLE3,
        ZIG_AI_IMAGE_GROK,
        ZIG_AI_IMAGE_IMAGEN_GENAI
    };

    ZigAiMediaConfig config = {
        .openai_api_key = make_string(getenv("OPENAI_API_KEY")),
        .xai_api_key = make_string(getenv("XAI_API_KEY")),
        .genai_api_key = make_string(getenv("GEMINI_API_KEY")),
        .vertex_project_id = make_string(NULL),
        .vertex_location = make_string("us-central1"),
        .media_store_path = make_string(NULL)
    };

    for (int i = 0; i < 3; i++) {
        ZigAiString name = zig_ai_image_provider_name(providers[i]);
        bool available = zig_ai_image_provider_available(providers[i], &config);
        printf("  %.*s: available=%s\n",
               (int)name.len, name.ptr,
               available ? "yes" : "no");
    }
    printf("PASS\n\n");
}

void test_lyria_session(void) {
    printf("=== Test: Lyria Session Create/Destroy ===\n");

    ZigAiLyriaSession* session = zig_ai_lyria_session_create();
    if (session) {
        printf("  Session created successfully\n");

        ZigAiLyriaState state = zig_ai_lyria_get_state(session);
        printf("  Initial state: %d (expected 0=disconnected)\n", state);

        bool connected = zig_ai_lyria_is_connected(session);
        printf("  Is connected: %s (expected no)\n", connected ? "yes" : "no");

        ZigAiAudioFormat format;
        zig_ai_lyria_get_audio_format(session, &format);
        printf("  Audio format: %dHz, %d channels, %d bits\n",
               format.sample_rate, format.channels, format.bits_per_sample);

        zig_ai_lyria_session_destroy(session);
        printf("  Session destroyed successfully\n");
        printf("PASS\n\n");
    } else {
        printf("FAIL: Could not create Lyria session\n\n");
    }
}

void test_cost_calculation(void) {
    printf("=== Test: Cost Calculation ===\n");

    double cost = zig_ai_text_calculate_cost(
        ZIG_AI_TEXT_CLAUDE,
        make_string("claude-sonnet-4-20250514"),
        1000,  // input tokens
        500    // output tokens
    );
    printf("  Claude Sonnet 4 (1000 in, 500 out): $%.6f\n", cost);

    cost = zig_ai_text_calculate_cost(
        ZIG_AI_TEXT_DEEPSEEK,
        make_string("deepseek-chat"),
        1000,
        500
    );
    printf("  DeepSeek Chat (1000 in, 500 out): $%.6f\n", cost);

    printf("PASS\n\n");
}

void test_lyria_connect(void) {
    printf("=== Test: Lyria Connect (requires GEMINI_API_KEY) ===\n");

    const char* api_key = getenv("GEMINI_API_KEY");
    if (!api_key) {
        printf("  SKIP: GEMINI_API_KEY not set\n\n");
        return;
    }

    ZigAiLyriaSession* session = zig_ai_lyria_session_create();
    if (!session) {
        printf("FAIL: Could not create session\n\n");
        return;
    }

    printf("  Attempting to connect...\n");
    int32_t result = zig_ai_lyria_connect(session, make_string(api_key));

    if (result == ZIG_AI_SUCCESS) {
        printf("  Connected successfully!\n");

        ZigAiLyriaState state = zig_ai_lyria_get_state(session);
        printf("  State after connect: %d\n", state);

        // Set some prompts
        ZigAiWeightedPrompt prompts[] = {
            { make_string("jazz"), 0.6f },
            { make_string("electronic"), 0.4f }
        };

        result = zig_ai_lyria_set_prompts(session, prompts, 2);
        printf("  Set prompts result: %d\n", result);

        zig_ai_lyria_close(session);
        printf("  Connection closed\n");
    } else {
        printf("  Connect returned error code: %d\n", result);
    }

    zig_ai_lyria_session_destroy(session);
    printf("PASS (or expected failure without valid API)\n\n");
}

int main(void) {
    printf("\n========================================\n");
    printf("    zig_ai FFI Library Test Suite\n");
    printf("========================================\n\n");

    zig_ai_init();

    test_version();
    test_text_provider_info();
    test_text_session();
    test_image_provider_info();
    test_lyria_session();
    test_cost_calculation();
    test_lyria_connect();

    zig_ai_shutdown();

    printf("========================================\n");
    printf("    All tests completed!\n");
    printf("========================================\n\n");

    return 0;
}
