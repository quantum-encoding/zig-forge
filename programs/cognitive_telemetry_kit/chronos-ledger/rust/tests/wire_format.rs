//! Verifies the emit-client produces exactly the body the Zig sink expects,
//! by binding our own datagram socket as a stand-in sink — no daemon needed.

use chronos_ledger::{Chronos, Event, Trust};
use std::os::unix::net::UnixDatagram;
use std::time::Duration;

#[test]
fn emit_reaches_a_bound_sink_with_expected_shape() {
    let sock = std::env::temp_dir().join(format!("chronos-rust-test-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&sock);
    let server = UnixDatagram::bind(&sock).expect("bind stand-in sink");
    server.set_read_timeout(Some(Duration::from_secs(2))).unwrap();

    let chronos = Chronos::with_socket(&sock, "rust_gui")
        .model("gpt-5.5")
        .session("sess-1");
    assert!(chronos.emit(&Event::exec("cargo test").trust(Trust::Repo).tool("run_command")));

    let mut buf = [0u8; 8192];
    let n = server.recv(&mut buf).expect("recv event");
    let v: serde_json::Value = serde_json::from_slice(&buf[..n]).expect("valid json");

    assert_eq!(v["kind"], "exec");
    assert_eq!(v["act"]["detail"], "cargo test");
    assert_eq!(v["act"]["source_trust"], "repo");
    assert_eq!(v["act"]["tool"], "run_command");
    assert_eq!(v["agent"]["id"], "rust_gui");
    assert_eq!(v["agent"]["model"], "gpt-5.5");
    assert_eq!(v["agent"]["session"], "sess-1");
    assert!(v["t_wall_ms"].is_string());
    // The sink owns these — they must NOT come from the client.
    for reserved in ["seq", "prev", "this", "sig", "v"] {
        assert!(v.get(reserved).is_none(), "reserved key {reserved} leaked");
    }

    let _ = std::fs::remove_file(&sock);
}

#[test]
fn emit_is_fail_fast_when_sink_absent() {
    let chronos = Chronos::with_socket("/tmp/chronos-rust-nonexistent.sock", "rust_gui");
    // No sink bound → send fails, but never panics, never blocks.
    assert!(!chronos.emit(&Event::read("/etc/hosts")));
}
