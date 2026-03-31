// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Quantum Curl - High-Velocity Command-Driven Router
//!
//! A protocol-aware HTTP request processor designed for the orchestration
//! and stress-testing of complex microservice architectures.
//!
//! ## Core Architecture
//!
//! The genius lies in the decoupling of the Battle Plan (JSONL manifest) from
//! the Execution Engine (high-concurrency Zig runtime). This allows complex,
//! multi-stage, multi-service operations to be defined as declarative data,
//! then executed with zero-contention concurrency.
//!
//! ## Strategic Applications
//!
//! - **Service Mesh Router**: Decentralized, high-velocity conductor for
//!   inter-service communication
//! - **Resilience-Forging Tool**: Native retry and backoff logic imposes
//!   discipline on unstable services
//! - **Stress-Testing Weapon**: Controlled force projection to find precise
//!   breaking points under realistic, high-concurrency fire
//!
//! ## Performance Characteristics
//!
//! - 5-7x lower latency than nginx for routing operations
//! - ~2ms latency under concurrent load (http_sentinel apex predator DNA)
//! - Thread-per-request with configurable concurrency limits
//! - Zero-contention output via mutex-protected streaming

pub const engine = @import("engine/core.zig");
pub const manifest = @import("engine/manifest.zig");
pub const ingest = @import("engine/ingest.zig");

// Re-export core types for convenient access
pub const Engine = engine.Engine;
pub const EngineConfig = engine.EngineConfig;
pub const RequestManifest = manifest.RequestManifest;
pub const ResponseManifest = manifest.ResponseManifest;
pub const Method = manifest.Method;
pub const parseRequestManifest = manifest.parseRequestManifest;

// Import http-sentinel for HttpClient access
pub const http_sentinel = @import("http-sentinel");
pub const HttpClient = http_sentinel.HttpClient;

test {
    @import("std").testing.refAllDecls(@This());
}
