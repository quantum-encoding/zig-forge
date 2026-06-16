#if canImport(SwiftUI)
import SwiftUI

/// Drop-in "View Audit Log" panel. Reads the signed NDJSON ledger (from the App
/// Group container the sink writes to) and shows a verification banner + the
/// per-action history. Verification is delegated (the sink service does the
/// crypto) — pass `XPCChronos.verifyLedger` as `verify`.
///
/// ```swift
/// AuditLogView(ledgerURL: groupLedgerURL) { await chronos.verifyLedger() }
/// ```
@available(macOS 12.0, iOS 15.0, *)
public struct AuditLogView: View {
    private let ledgerURL: URL
    private let verify: (() async -> LedgerVerdict?)?

    @State private var entries: [LedgerEntry] = []
    @State private var verdict: LedgerVerdict?
    @State private var loaded = false

    public init(ledgerURL: URL, verify: (() async -> LedgerVerdict?)? = nil) {
        self.ledgerURL = ledgerURL
        self.verify = verify
    }

    public var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            if loaded && entries.isEmpty {
                empty
            } else {
                List(entries) { EntryRow(entry: $0) }
                #if os(macOS)
                    .listStyle(.inset)
                #else
                    .listStyle(.plain)
                #endif
            }
        }
        .task { await reload() }
    }

    private var banner: some View {
        let icon: String
        let tint: Color
        let text: String
        if let v = verdict {
            if v.isValid {
                icon = "checkmark.seal.fill"
                tint = .green
                text = "\(v.events) events · \(v.signed) signed — chain intact, signatures valid"
            } else {
                icon = "exclamationmark.triangle.fill"
                tint = .red
                text =
                    "Tampering detected\(v.firstBadSeq.map { " at seq \($0)" } ?? "") — chain or signature failed"
            }
        } else {
            icon = "clock.arrow.circlepath"
            tint = .secondary
            text = "\(entries.count) events — verifying…"
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(tint == .secondary ? Color.primary : tint)
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(.secondary)
            Text("No audit events yet").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        verdict = nil
        if let data = try? Data(contentsOf: ledgerURL) {
            entries = LedgerEntry.parse(ndjson: data)
        }
        if let verify { verdict = await verify() }
        loaded = true
    }
}

@available(macOS 12.0, iOS 15.0, *)
private struct EntryRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.seq)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(entry.kind.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(kindColor.opacity(0.18))
                .foregroundStyle(kindColor)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.detail ?? entry.tool ?? "—").font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.agent).font(.caption2).foregroundStyle(.secondary)
                    if let t = entry.trust {
                        Text(t).font(.caption2)
                            .foregroundStyle(t == "web" || t == "external" ? Color.orange : Color.secondary)
                    }
                }
            }
            Spacer()
            if entry.signed {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var kindColor: Color {
        switch entry.kind {
        case "net": return .orange
        case "write": return .blue
        case "exec": return .purple
        case "read": return .gray
        case "search": return .teal
        default: return .secondary
        }
    }
}
#endif
