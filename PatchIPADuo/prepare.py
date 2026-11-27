"""Generate the iOS core from the pinned upstream script; run before xcodebuild."""
import hashlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
upstream = Path(sys.argv[1])
script = (upstream / 'patch-ipa-duo').read_bytes()
if hashlib.sha256(script).hexdigest() != '9d6a49c66688f861fba371a5d97c813af165adb1c6edb466a846f19815e2b2fc':
    sys.exit('Unexpected upstream revision')
lines = script.decode().splitlines(keepends=True)
def section(start, end):
    return ''.join(lines[start-1:end])

# Keep the upstream readers, validation, SDK resolver, and patch transaction.
core = ('// Port of patriot1889/patch-ipa-duo, revision f4ce0f57.\n' +
        section(2, 13) + section(20, 27) + section(73, 648) +
        section(743, 865) + section(1059, 1157) +
        section(1246, 1328))
core += '''
extension Problem: LocalizedError {
    var errorDescription: String? { description }
}
'''
plex = (upstream / 'adapters/com.plexapp.plex/adapter.json').read_text()
core += 'private let plexManifest = #"""\n' + plex + '\n"""#\n'
core += '''
struct PatchResult {
    let report: String
    let output: URL?
}

enum IPAPatcher {
    static func run(_ input: URL, display: String, enablePhone: Bool, inspect: Bool) throws -> PatchResult {
        let fm = FileManager.default
        let directory = try temporaryDirectory()
        var published = false
        defer { if !published { try? fm.removeItem(at: directory) } }
        let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-duo.ipa")
        var args = ["inspect", input.path]
        if !inspect {
            args = ["patch", input.path, "--display", display, "--output", output.path]
            if enablePhone { args.append("--enable-iphone") }
        }
        let report = try process(args)
        published = !inspect
        return PatchResult(report: report, output: inspect ? nil : output)
    }
}
private func process(_ args: [String]) throws -> String {
    var log: [String] = []
    func print(_ message: String) { log.append(message) }
'''
core += section(1332, 1355)
assert core.rstrip().endswith('let info = try plist(Data(contentsOf: infoURL))')
core += '''
    let plex = try JSONDecoder().decode(PatchAdapter.self, from: Data(plexManifest.utf8))
    let adapter = patchMatchAdapter(info, adapters: [plex])
    let mixPad = app.id == "com.allenheath.SQU.MixPad"
'''
core += section(1357, 1363)
core += '''
    if options.inspect {
        if mixPad { print("SQ MixPad requires the macOS native adapter.") }
        return log.joined(separator: "\\n")
    }
    guard !mixPad else { throw Problem("SQ MixPad requires the macOS adapter and executable transform.") }
'''
core += section(1375, 1378) + section(1380, 1382)  # options and SDK
core += section(1393, 1403)
core += section(1419, 1426)
core += '''
    try FileManager.default.zipItem(at: work.appendingPathComponent("Payload"), to: archive, compressionMethod: .deflate)
'''
core += section(1429, 1436)
core += '    return log.joined(separator: "\\n")\n}\n'
(root/'App/Core.swift').write_text('import ZIPFoundation\n' + core)
