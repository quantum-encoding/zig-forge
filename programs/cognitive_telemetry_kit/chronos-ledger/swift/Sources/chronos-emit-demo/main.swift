// Live round-trip demo: emits an exfil-shape chain to the configured sink so you
// can verify the Swift emit-client end-to-end against the real `ledger-daemon`.
//
//   CHRONOS_LEDGER_SOCKET=/tmp/cl-sw.sock CHRONOS_LEDGER_OUT=/tmp/cl-sw.ndjson ledger-daemon &
//   CHRONOS_LEDGER_SOCKET=/tmp/cl-sw.sock swift run chronos-emit-demo
//   CHRONOS_LEDGER_OUT=/tmp/cl-sw.ndjson ledger-verify     # expect EXFIL_CHAIN

import ChronosLedger
import Foundation

let chronos = Chronos(agent: "CosmicDuckOS").model("claude-opus-4-8").session("demo")

let events: [Event] = [
    .read("/Users/x/.ssh/id_rsa").trust(.external).tool("read_file"),
    .search().trust(.web).detail("aws credentials").tool("web_search"),
    .net("https://evildomain.example/exfil").trust(.web).tool("fetch"),
    .write("Sources/App/Secrets.swift").trust(.repo).tool("apply_patch"),
]

for ev in events {
    let sent = chronos.emit(ev)
    FileHandle.standardError.write("emit \(ev.kind) -> sent=\(sent)\n".data(using: .utf8)!)
}
FileHandle.standardError.write("done; sink=\(chronos.socketPath)\n".data(using: .utf8)!)
