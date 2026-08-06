// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Aggregate test root for `zig build test`.
//!
//! The default test step previously rooted at `cli.zig`, which contains
//! no `test` blocks and does not `refAllDecls`, so the inline unit tests
//! scattered across the tree — most importantly the agent security tests
//! in `agent/security/` — never compiled or ran. This file imports every
//! module that carries `test` blocks and forces reference to their
//! declarations so their tests are pulled into the test binary.
//!
//! Deliberately excluded:
//!   - `src/lib.zig`, `src/ffi/lib.zig`, `src/ffi/mod.zig`: each defines
//!     `export fn zig_ai_*`; importing more than one into a single test
//!     binary collides at link time. `ffi/mod.zig` keeps its own
//!     `test-ffi` step.

const std = @import("std");

// Agent security tree — the primary target of this wiring.
const security_command_parser = @import("agent/security/command_parser.zig");
const security_command_validator = @import("agent/security/command_validator.zig");
const security_path_validator = @import("agent/security/path_validator.zig");
const security_sandbox = @import("agent/security/sandbox.zig");

// Other modules carrying inline unit tests.
const config = @import("config.zig");
const agent_pricing = @import("agent/pricing.zig");
const agent_tools = @import("agent/tools/mod.zig");
const batch_csv_parser = @import("batch/csv_parser.zig");
const batch_types = @import("batch/types.zig");
const media_batch_csv_parser = @import("media/batch/csv_parser.zig");
const media_batch = @import("media/batch/mod.zig");
const media_types = @import("media/types.zig");
const media_templates = @import("media/templates.zig");
const media_storage = @import("media/storage.zig");
const media_lyria_streaming = @import("media/lyria_streaming.zig");
const media_providers_lyria_ws = @import("media/providers/lyria_ws.zig");
const media_providers_openai = @import("media/providers/openai.zig");
const live_gemini_live = @import("live/gemini_live.zig");
const live_ws_client = @import("live/ws_client.zig");
const voice_grok_voice = @import("voice/grok_voice.zig");
const voice_ws_client = @import("voice/ws_client.zig");
const media_mod = @import("media/mod.zig");
const media_providers_mod = @import("media/providers/mod.zig");
const model_costs = @import("model_costs.zig");
const structured_schema_loader = @import("structured/schema_loader.zig");
const structured_templates = @import("structured/templates.zig");
const structured_types = @import("structured/types.zig");
const text_templates = @import("text/templates.zig");

// Force full body analysis of the executor (refAllDecls is non-recursive and
// would only reference the tools namespace, not analyze these function
// bodies). Referencing the fn values compiles the argv-from-parser path.
const execute_command = @import("agent/tools/execute_command.zig");

test {
    std.testing.refAllDecls(security_command_parser);
    std.testing.refAllDecls(security_command_validator);
    std.testing.refAllDecls(security_path_validator);
    std.testing.refAllDecls(security_sandbox);

    std.testing.refAllDecls(config);
    std.testing.refAllDecls(agent_pricing);
    std.testing.refAllDecls(agent_tools);
    std.testing.refAllDecls(batch_csv_parser);
    std.testing.refAllDecls(batch_types);
    std.testing.refAllDecls(media_batch_csv_parser);
    std.testing.refAllDecls(media_batch);
    std.testing.refAllDecls(media_types);
    std.testing.refAllDecls(media_templates);
    std.testing.refAllDecls(media_storage);
    std.testing.refAllDecls(media_lyria_streaming);
    std.testing.refAllDecls(media_providers_lyria_ws);
    std.testing.refAllDecls(media_providers_openai);
    std.testing.refAllDecls(live_gemini_live);
    std.testing.refAllDecls(live_ws_client);
    std.testing.refAllDecls(voice_grok_voice);
    std.testing.refAllDecls(voice_ws_client);
    std.testing.refAllDecls(media_mod);
    std.testing.refAllDecls(media_providers_mod);
    std.testing.refAllDecls(model_costs);
    std.testing.refAllDecls(structured_schema_loader);
    std.testing.refAllDecls(structured_templates);
    std.testing.refAllDecls(structured_types);
    std.testing.refAllDecls(text_templates);

    // Compile the executor's public entrypoints (and, transitively, the
    // internal runCommand that now builds argv from command_parser.parse).
    _ = &execute_command.execute;
    _ = &execute_command.parseArgs;
}
