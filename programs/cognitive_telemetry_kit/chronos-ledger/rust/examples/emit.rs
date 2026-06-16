//! Live round-trip demo: emits an exfil-shape chain to the configured sink so you
//! can verify the Rust emit-client end-to-end against the real `ledger-daemon`.
//!
//!   # terminal 1 — the sink
//!   CHRONOS_LEDGER_SOCKET=/tmp/cl-rust.sock CHRONOS_LEDGER_OUT=/tmp/cl-rust.ndjson ledger-daemon
//!   # terminal 2 — emit, then audit
//!   CHRONOS_LEDGER_SOCKET=/tmp/cl-rust.sock cargo run --example emit
//!   CHRONOS_LEDGER_OUT=/tmp/cl-rust.ndjson ledger-verify   # expect EXFIL_CHAIN

use chronos_ledger::{Chronos, Event, Trust};

fn main() {
    let chronos = Chronos::new("rust_gui").model("gpt-5.5").session("demo");
    let events = [
        Event::read("/Users/x/.ssh/id_rsa").trust(Trust::External).tool("read_file"),
        Event::search().trust(Trust::Web).detail("aws credentials").tool("web_search"),
        Event::net("https://evildomain.example/exfil").trust(Trust::Web).tool("fetch"),
        Event::write("src/git.rs").trust(Trust::Repo).tool("apply_patch"),
    ];
    for ev in &events {
        let sent = chronos.emit(ev);
        eprintln!("emit {:?} -> sent={sent}", ev.kind);
    }
    eprintln!("done; sink={}", chronos.socket_path().display());
}
