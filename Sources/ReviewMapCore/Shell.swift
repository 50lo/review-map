import Foundation

struct ShellError: Error, CustomStringConvertible {
    var command: String
    var status: Int32
    var stderr: String
    var description: String { "`\(command)` failed (\(status)): \(stderr)" }
}

enum Shell {
    /// Runs a program and returns stdout. Throws on non-zero exit.
    @discardableResult
    static func run(_ args: [String], cwd: String? = nil, stdoutTo: FileHandle? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = stdoutTo ?? out
        p.standardError = err
        try p.run()
        // Drain both pipes concurrently to avoid deadlocks on large outputs.
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box()
        let errBox = Box()
        let group = DispatchGroup()
        if stdoutTo == nil {
            group.enter()
            DispatchQueue.global().async {
                outBox.data = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        p.waitUntilExit()
        group.wait()
        let outData = outBox.data
        let errData = errBox.data
        if p.terminationStatus != 0 {
            throw ShellError(command: args.joined(separator: " "), status: p.terminationStatus,
                             stderr: String(decoding: errData, as: UTF8.self))
        }
        return outData
    }

    static func string(_ args: [String], cwd: String? = nil) throws -> String {
        String(decoding: try run(args, cwd: cwd), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Read-only access to the target repository. Nothing here writes to the repo or its .git directory.
struct GitRepo {
    let root: String

    func revParse(_ ref: String) throws -> String {
        try Shell.string(["git", "-C", root, "rev-parse", "--verify", "\(ref)^{commit}"])
    }

    func mergeBase(_ a: String, _ b: String) throws -> String {
        try Shell.string(["git", "-C", root, "merge-base", a, b])
    }

    /// path -> blob sha for every file in the commit.
    func blobs(at sha: String) throws -> [String: String] {
        let out = try Shell.run(["git", "-C", root, "ls-tree", "-r", "-z", sha])
        var result: [String: String] = [:]
        for entry in out.split(separator: 0) {
            // "<mode> <type> <sha>\t<path>"
            guard let tab = entry.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let meta = String(decoding: entry[entry.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: entry[entry.index(after: tab)...], as: UTF8.self)
            guard meta.count == 3, meta[1] == "blob" else { continue }
            result[path] = String(meta[2])
        }
        return result
    }

    /// Exports the tree at `sha` into `dir` (like a worktree, but without touching the repo's .git).
    func export(_ sha: String, to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tarPath = dir + ".tar"
        FileManager.default.createFile(atPath: tarPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tarPath))
        try Shell.run(["git", "-C", root, "archive", "--format=tar", sha], stdoutTo: handle)
        try handle.close()
        try Shell.run(["tar", "-xf", tarPath, "-C", dir])
        try? FileManager.default.removeItem(atPath: tarPath)
    }
}
