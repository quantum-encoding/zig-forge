//! Embeddable emit-client for the **Chronos accountability ledger**.
//!
//! Drop this into any Rust app (an agent host like `rust_gui`, a tool, a service)
//! and every sensitive action becomes a structured event on the tamper-evident
//! ledger — "chronos, built in".
//!
//! # Why this is tiny (no FFI, no crypto)
//!
//! In the Chronos threat model the audited process is *adversarial*, so the
//! emit-client holds **no signing key and does no canonicalization**. It only
//! serializes the event body and fires it at the privileged **sink** (the
//! `ledger-daemon` / Guardian Shield) over an `AF_UNIX` datagram socket. The
//! sink does the RFC 8785 canonicalization, hash-chaining, and ML-DSA-65
//! signing. So this crate is just `serde_json` + a non-blocking `send_to` — the
//! same wire contract `chronos-hook` uses, so the sink ingests app-origin and
//! hook-origin events identically.
//!
//! # Contract
//!
//! - **Non-blocking, fire-and-forget.** [`Chronos::emit`] never blocks the
//!   caller and swallows all errors (returns whether it was sent). If the sink
//!   is down or its buffer is full, the event is dropped — and a dropped event
//!   shows up as a gap in the ledger's monotonic `seq`, which is itself the
//!   signal. The audit path can never stall or crash your UI thread.
//! - **The app supplies only the body** (kind/act/agent/state/timestamp). It
//!   must NOT set `seq`/`prev`/`this`/`sig`/`v` — the sink owns those.
//! - **Float-free by design** (matches the ledger's canonicalization rules):
//!   every field is a string, enum-as-string, or nested object. No numbers reach
//!   the wire, so cross-language hashing stays deterministic.
//!
//! # Example
//!
//! ```no_run
//! use chronos_ledger::{Chronos, Event, Trust};
//!
//! let chronos = Chronos::new("rust_gui");           // socket from $CHRONOS_LEDGER_SOCKET
//! chronos.emit(&Event::exec("cargo test").trust(Trust::Repo).tool("run_command"));
//! chronos.emit(&Event::write("src/git.rs").tool("apply_patch"));
//! chronos.emit(&Event::net("https://api.openai.com/v1/responses").trust(Trust::Web));
//! ```

use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

/// Default sink socket if `$CHRONOS_LEDGER_SOCKET` is unset.
pub const DEFAULT_SOCKET: &str = "/tmp/chronos-ledger.sock";

/// Emitter bound to one agent identity + sink socket. Cheap to clone.
#[derive(Clone, Debug)]
pub struct Chronos {
    socket_path: PathBuf,
    agent: String,
    session: Option<String>,
    model: Option<String>,
    user: Option<String>,
}

impl Chronos {
    /// Emitter for `agent` (e.g. `"rust_gui"`, `"claude"`). Socket path is taken
    /// from `$CHRONOS_LEDGER_SOCKET`, else [`DEFAULT_SOCKET`].
    pub fn new(agent: impl Into<String>) -> Self {
        let socket_path = std::env::var_os("CHRONOS_LEDGER_SOCKET")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_SOCKET));
        Self {
            socket_path,
            agent: agent.into(),
            session: None,
            model: None,
            user: None,
        }
    }

    /// Emitter with an explicit sink socket path.
    pub fn with_socket(socket_path: impl Into<PathBuf>, agent: impl Into<String>) -> Self {
        Self {
            socket_path: socket_path.into(),
            agent: agent.into(),
            session: None,
            model: None,
            user: None,
        }
    }

    /// Tag events with a session id (builder).
    pub fn session(mut self, session: impl Into<String>) -> Self {
        self.session = Some(session.into());
        self
    }

    /// Tag events with the active model slug (builder).
    pub fn model(mut self, model: impl Into<String>) -> Self {
        self.model = Some(model.into());
        self
    }

    /// Tag events with a user id (builder).
    pub fn user(mut self, user: impl Into<String>) -> Self {
        self.user = Some(user.into());
        self
    }

    /// The sink socket path this emitter targets.
    pub fn socket_path(&self) -> &std::path::Path {
        &self.socket_path
    }

    /// Fire one event at the sink. Non-blocking and best-effort: returns `true`
    /// if the datagram was handed to the kernel, `false` if the sink was
    /// unavailable / busy (the event is then dropped — never retried, never
    /// blocks). Safe to call from a UI thread.
    pub fn emit(&self, event: &Event) -> bool {
        let body = WireBody {
            agent: WireAgent {
                id: &self.agent,
                session: self.session.as_deref(),
                model: self.model.as_deref(),
                user: self.user.as_deref(),
            },
            kind: event.kind,
            state: event.state.as_deref(),
            act: &event.act,
            t_wall_ms: now_ms().to_string(),
        };
        let payload = match serde_json::to_vec(&body) {
            Ok(p) => p,
            Err(_) => return false,
        };
        self.send(&payload)
    }

    fn send(&self, payload: &[u8]) -> bool {
        let Ok(sock) = UnixDatagram::unbound() else {
            return false;
        };
        // Non-blocking so a full sink buffer fails fast instead of stalling us.
        let _ = sock.set_nonblocking(true);
        sock.send_to(payload, &self.socket_path).is_ok()
    }
}

/// The action class. Mirrors the ledger schema `kind`; drives the sink's
/// milestone-signing policy (net/write are signed) and the detector's rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Read,
    Write,
    Exec,
    Net,
    Search,
    Think,
    Other,
}

/// Trust level of the data a `read`/`net` touched. Once a session reads
/// `External`/`Web` content, the detector treats it as tainted and confines
/// egress to a pinned allowlist (domain-segmented taint).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Trust {
    Repo,
    External,
    Web,
    User,
    Unknown,
}

/// Per-action detail. Provide what's relevant for the kind; the rest stays out
/// of the payload.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Act {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dest_host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_trust: Option<Trust>,
}

/// One ledger event the app constructs and emits. Builder-style.
#[derive(Debug, Clone, Serialize)]
pub struct Event {
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    pub act: Act,
}

impl Event {
    /// Bare event of `kind` — prefer the named constructors below.
    pub fn new(kind: Kind) -> Self {
        Self {
            kind,
            state: None,
            act: Act::default(),
        }
    }

    /// A file read. `path` is the resource read.
    pub fn read(path: impl Into<String>) -> Self {
        Self::new(Kind::Read).path(path)
    }

    /// A file write / edit. `path` is the resource written.
    pub fn write(path: impl Into<String>) -> Self {
        Self::new(Kind::Write).path(path)
    }

    /// A command / shell execution. `command` goes in `detail`.
    pub fn exec(command: impl Into<String>) -> Self {
        Self::new(Kind::Exec).detail(command)
    }

    /// A network egress to `url`. The host is also extracted into `dest_host`
    /// so the detector can match it against the egress allowlist directly.
    pub fn net(url: impl Into<String>) -> Self {
        let url = url.into();
        let host = host_of(&url);
        let mut ev = Self::new(Kind::Net).url(url);
        if let Some(h) = host {
            ev.act.dest_host = Some(h);
        }
        ev
    }

    /// A search. Provide a hashed/opaque query via `detail` if it may carry
    /// secrets (the ledger stores hashes, not raw queries).
    pub fn search() -> Self {
        Self::new(Kind::Search)
    }

    /// A reasoning/thinking marker carrying the cognitive `state`.
    pub fn think(state: impl Into<String>) -> Self {
        Self::new(Kind::Think).state(state)
    }

    /// Set the tool name (e.g. `"apply_patch"`, `"run_command"`).
    pub fn tool(mut self, tool: impl Into<String>) -> Self {
        self.act.tool = Some(tool.into());
        self
    }

    /// Set the resource path.
    pub fn path(mut self, path: impl Into<String>) -> Self {
        self.act.path = Some(path.into());
        self
    }

    /// Set a free-form detail (command text, summary, …).
    pub fn detail(mut self, detail: impl Into<String>) -> Self {
        self.act.detail = Some(detail.into());
        self
    }

    /// Set the egress URL.
    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.act.url = Some(url.into());
        self
    }

    /// Set the egress host explicitly (otherwise derived from `url` for `net`).
    pub fn dest_host(mut self, host: impl Into<String>) -> Self {
        self.act.dest_host = Some(host.into());
        self
    }

    /// Set the data trust level.
    pub fn trust(mut self, trust: Trust) -> Self {
        self.act.source_trust = Some(trust);
        self
    }

    /// Set the cognitive state string (the gerund / activity).
    pub fn state(mut self, state: impl Into<String>) -> Self {
        self.state = Some(state.into());
        self
    }
}

// ── wire body (matches chronos-hook's emit shape; sink injects seq/prev/this) ──

#[derive(Serialize)]
struct WireBody<'a> {
    agent: WireAgent<'a>,
    kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<&'a str>,
    act: &'a Act,
    /// Wall-clock ms as a STRING — display only; the sink's `seq` is the order
    /// of record. A string keeps it out of the float/`>2^53` hazard zone.
    t_wall_ms: String,
}

#[derive(Serialize)]
struct WireAgent<'a> {
    id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    session: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user: Option<&'a str>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Extract the host from a URL-ish string: strip scheme + optional userinfo,
/// stop at the first `/ : ? #`. Mirrors the detector's `parseHost`.
fn host_of(url: &str) -> Option<String> {
    let mut s = url;
    if let Some(i) = s.find("://") {
        s = &s[i + 3..];
    }
    if let Some(at) = s.find('@') {
        s = &s[at + 1..];
    }
    let end = s
        .find(|c| matches!(c, '/' | ':' | '?' | '#'))
        .unwrap_or(s.len());
    let host = &s[..end];
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn net_derives_host() {
        let ev = Event::net("https://user@evil.example:8443/exfil?q=1");
        assert_eq!(ev.act.dest_host.as_deref(), Some("evil.example"));
        assert_eq!(ev.act.url.as_deref(), Some("https://user@evil.example:8443/exfil?q=1"));
    }

    #[test]
    fn body_has_no_reserved_keys_and_no_numbers() {
        // The sink owns seq/prev/this/sig/v; the body must not carry them, and
        // must be float/number-free for deterministic canonicalization.
        let chronos = Chronos::with_socket("/tmp/unused.sock", "rust_gui").model("gpt-5.5");
        let body = WireBody {
            agent: WireAgent {
                id: &chronos.agent,
                session: None,
                model: chronos.model.as_deref(),
                user: None,
            },
            kind: Kind::Write,
            state: Some("Writing"),
            act: &Event::write("src/git.rs").tool("apply_patch").act,
            t_wall_ms: "1750000000000".into(),
        };
        let v: serde_json::Value = serde_json::to_value(&body).unwrap();
        for reserved in ["seq", "prev", "this", "sig", "v"] {
            assert!(v.get(reserved).is_none(), "reserved key {reserved} leaked");
        }
        assert!(v["t_wall_ms"].is_string(), "t_wall_ms must be a string");
        assert_eq!(v["kind"], "write");
        assert_eq!(v["act"]["tool"], "apply_patch");
        assert_eq!(v["agent"]["model"], "gpt-5.5");
        // No floating-point anywhere in the tree.
        assert!(!has_float(&v), "payload must be float-free");
    }

    fn has_float(v: &serde_json::Value) -> bool {
        match v {
            serde_json::Value::Number(n) => n.is_f64(),
            serde_json::Value::Array(a) => a.iter().any(has_float),
            serde_json::Value::Object(o) => o.values().any(has_float),
            _ => false,
        }
    }
}
