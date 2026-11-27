import Foundation
import ZIPFoundation

struct PatchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum IPAPatcher {
    static func run(_ input: URL) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-SDK27.2.ipa")
        do {
            let scoped = input.startAccessingSecurityScopedResource()
            defer { if scoped { input.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: input, options: [], error: &coordinationError) { source in
                do { try fm.copyItem(at: source, to: output) } catch { copyError = error }
            }
            if let error = coordinationError ?? (copyError as NSError?) { throw error }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            try rewrite(output, in: directory)
            return output
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private static func rewrite(_ output: URL, in directory: URL) throws {
        let archive = try Archive(url: output, accessMode: .update)
        var paths = Set<String>()
        var manifests: [Entry] = []
        for entry in archive {
            guard paths.insert(entry.path).inserted else { throw PatchError("Duplicate IPA entry.") }
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                manifests.append(entry)
            }
        }
        guard manifests.count == 1, let manifest = manifests.first, manifest.type == .file else {
            throw PatchError("Choose an IPA containing one main application.")
        }
        var data = Data()
        let checksum = try archive.extract(manifest) { chunk in
            guard data.count + chunk.count <= 16 * 1024 * 1024 else { throw PatchError("Oversized Info.plist.") }
            data.append(chunk)
        }
        guard checksum == manifest.checksum else { throw PatchError("Info.plist checksum mismatch.") }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
              !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw PatchError("Missing or invalid CFBundleExecutable.")
        }
        let path = String(manifest.path.dropLast("Info.plist".count)) + name
        guard let binary = archive[path], binary.type == .file else { throw PatchError("Main executable is missing.") }
        let fm = FileManager.default
        let scratch = directory.appendingPathComponent("executable")
        defer { try? fm.removeItem(at: scratch) }
        guard try archive.extract(binary, to: scratch) == binary.checksum else {
            throw PatchError("Executable checksum mismatch.")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)
        if let error = patch_sdk_file(scratch.path) { throw PatchError(String(cString: error)) }
        info["DTSDKName"] = "iphoneos27.2"
        info["DTPlatformVersion"] = "27.2"
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)

        try archive.remove(binary)
        // Removing an entry changes the offsets of later entries.
        guard let current = archive[manifest.path] else { throw PatchError("Could not reopen Info.plist.") }
        try archive.remove(current)
        let file = try FileHandle(forReadingFrom: scratch)
        defer { try? file.close() }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(binary.uncompressedSize),
                             permissions: permissions(binary, fallback: 0o755), compressionMethod: .deflate) { offset, size in
            try file.seek(toOffset: UInt64(offset))
            let bytes = try file.read(upToCount: size) ?? Data()
            guard bytes.count == size else { throw PatchError("Incomplete executable read.") }
            return bytes
        }
        try archive.addEntry(with: manifest.path, type: .file, uncompressedSize: Int64(plist.count),
                             permissions: permissions(manifest, fallback: 0o644), compressionMethod: .deflate) { offset, size in
            plist.subdata(in: Int(offset)..<(Int(offset) + size))
        }
    }

    private static func permissions(_ entry: Entry, fallback: UInt16) -> UInt16 {
        (entry.fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? fallback
    }
}
