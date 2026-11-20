// PDFKit (the framework macOS Preview is built on): list the form widgets of
// argv[1]; with argv[2], fill them the way a person would in Preview, save to
// argv[2], re-open the saved file and list what PDFKit reads back from it.
//
// It also writes <argv[2] minus .pdf>.expected.json: the values typed and
// ticked here (text fields not typed into keep the value they opened with).
// That is the intent, and the saved appearances show it; PDFKit's own re-read
// can differ for a checkbox it unticked, because it leaves the widget's /AS
// stale and only removes /V.
import Foundation
import PDFKit

func list(_ doc: PDFDocument) -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for p in 0..<doc.pageCount {
        guard let page = doc.page(at: p) else { continue }
        for a in page.annotations where a.type == "Widget" {
            var row: [String: Any] = ["page": p, "name": a.fieldName ?? "<nil>", "ft": a.widgetFieldType.rawValue]
            if a.widgetFieldType == .text { row["value"] = a.widgetStringValue ?? "<nil>" }
            if a.widgetFieldType == .button { row["checked"] = a.buttonWidgetState == .onState }
            rows.append(row)
        }
    }
    return rows
}

func dump(_ label: String, _ rows: [[String: Any]]) {
    print(label)
    for r in rows { print("  ", r.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
}

let ticks: [String: Bool] = ["rcd_tested": true, "ir_ok": false]

let input = URL(fileURLWithPath: CommandLine.arguments[1])
guard let doc = PDFDocument(url: input) else { print("PDFKit could not open"); exit(1) }
dump("read:", list(doc))
guard CommandLine.arguments.count > 2 else { exit(0) }

let fills: [String: String] = [
    "c3_zs": "0.42",
    "p2_note": "Checked on site 19/11 (\u{00A3}0)",
    "electrician": "R\u{00E9}mi \u{0141}ukasz",
    "remarks": "Re-tested after repair.\nAll readings within limits.",
]
for p in 0..<doc.pageCount {
    for a in doc.page(at: p)!.annotations where a.type == "Widget" {
        let n = a.fieldName ?? ""
        if let v = fills[n] { a.widgetStringValue = v }
        if let t = ticks[n] { a.buttonWidgetState = t ? .onState : .offState }
    }
}
var expected: [String: Any] = [:]
for row in list(PDFDocument(url: input)!) {
    let n = row["name"] as! String
    if let checked = row["checked"] as? Bool { expected[n] = ticks[n] ?? checked }
    else if let v = fills[n] ?? (row["value"] as? String), !v.isEmpty { expected[n] = v }
}

let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard doc.write(to: output) else { print("write failed"); exit(1) }
guard let back = PDFDocument(url: output) else { print("PDFKit could not reopen"); exit(1) }
dump("saved and re-read:", list(back))

let json = try! JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
let expectedPath = CommandLine.arguments[2].replacingOccurrences(of: ".pdf", with: ".expected.json")
try! (String(data: json, encoding: .utf8)! + "\n").write(toFile: expectedPath, atomically: true, encoding: .utf8)
