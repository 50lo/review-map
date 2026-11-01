import ArgumentParser
import Foundation

/// Starts the browser viewer (viewer/, a Vite app) on a change model and opens it.
enum ViewerLauncher {
    /// The viewer directory: $REVIEWMAP_VIEWER, or viewer/ in the checkout this binary was built from.
    static func directory() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["REVIEWMAP_VIEWER"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // reviewmap
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("viewer")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.json").path) else {
            throw ValidationError("Can't find the viewer at \(dir.path). Set REVIEWMAP_VIEWER to the viewer directory.")
        }
        return dir
    }

    /// Runs until the server is stopped (Ctrl-C).
    static func run(model: String, port: Int, open: Bool) throws {
        let dir = try directory()
        let modelPath = URL(fileURLWithPath: model).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ValidationError("No change model at \(modelPath).")
        }
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("node_modules").path) {
            log("Installing viewer dependencies (first run)…")
            try exec(["npm", "ci", "--no-audit", "--no-fund"], in: dir)
        }
        var args = ["npm", "run", "dev", "--", "--port", String(port), "--strictPort"]
        if open { args.append("--open") }
        log("Serving \(modelPath) at http://localhost:\(port)/ (Ctrl-C to stop)")
        try exec(args, in: dir, env: ["REVIEWMAP_MODEL": modelPath])
    }

    private static func exec(_ args: [String], in dir: URL, env: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0, p.terminationReason == .exit {
            throw ExitCode(p.terminationStatus)
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

struct ViewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Open an existing change-model.json in the browser viewer."
    )

    @Argument(help: "Path to the change model.")
    var model: String = "change-model.json"

    @Option(help: "Port for the local viewer server.")
    var port: Int = 5173

    @Flag(name: .customLong("no-open"), help: "Don't open a browser.")
    var noOpen = false

    func run() throws {
        try ViewerLauncher.run(model: model, port: port, open: !noOpen)
    }
}
