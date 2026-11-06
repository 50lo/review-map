import ArgumentParser
import Foundation

/// Starts the browser viewer (viewer/, a Vite app) on a change report and opens it.
enum ViewerLauncher {
    /// The viewer directory: $REVIEWMAP_VIEWER, then share/reviewmap/viewer next to the installed
    /// binary (scripts/install.sh), then viewer/ in the checkout this binary was built from.
    static func directory() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["REVIEWMAP_VIEWER"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("share/reviewmap/viewer"))
        }
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // reviewmap
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
            .appendingPathComponent("viewer"))
        if let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("package.json").path) }) {
            return dir
        }
        throw ValidationError("Can't find the viewer (looked in \(candidates.map(\.path).joined(separator: " and "))). "
            + "Run scripts/install.sh again, or set REVIEWMAP_VIEWER to the viewer directory.")
    }

    /// Runs until the server is stopped (Ctrl-C). `editor` overrides REVIEWMAP_EDITOR.
    static func run(report: String, port: Int, open: Bool, editor: String? = nil) throws {
        let dir = try directory()
        let reportPath = URL(fileURLWithPath: report).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: reportPath) else {
            throw ValidationError("No change report at \(reportPath).")
        }
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("node_modules").path) {
            log("Installing viewer dependencies (first run)…")
            try exec(["npm", "ci", "--no-audit", "--no-fund"], in: dir)
        }
        var args = ["npm", "run", "dev", "--", "--port", String(port), "--strictPort"]
        if open { args.append("--open") }
        log("Serving \(reportPath) at http://localhost:\(port)/ (Ctrl-C to stop)")
        var env = ["REVIEWMAP_REPORT": reportPath]
        if let editor { env["REVIEWMAP_EDITOR"] = editor }
        try exec(args, in: dir, env: env)
    }

    static let editorHelp = "Editor that Open uses: xcode, vscode, cursor, zed, idea, webstorm, goland, rustrover, "
        + "or a command with {file} and {line}, such as \"subl {file}:{line}\" (default: $REVIEWMAP_EDITOR, else xcode on macOS)."

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
        abstract: "Open an existing change-report.json in the browser viewer."
    )

    @Argument(help: "Path to the change report (default: the report of the current branch of the repo in the current directory).")
    var report: String?

    @Option(help: "Port for the local viewer server.")
    var port: Int = 5173

    @Flag(name: .customLong("no-open"), help: "Don't open a browser.")
    var noOpen = false

    @Option(help: ArgumentHelp(ViewerLauncher.editorHelp))
    var editor: String?

    func run() throws {
        try ViewerLauncher.run(report: try report ?? ReportPath.current(), port: port, open: !noOpen, editor: editor)
    }
}
