import ArgumentParser
import Foundation
import ReviewMapCore

struct ReviewMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reviewmap",
        abstract: "Structural review map for a Swift change.",
        version: Analyzer.version,
        subcommands: [Analyze.self, ViewCommand.self],
        defaultSubcommand: Analyze.self
    )
}

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze the change between two git refs and write change-model.json."
    )

    @Argument(help: "Path to the git repository (any directory inside it).")
    var repo: String = "."

    @Option(help: "Base ref (branch, tag, or sha).")
    var base: String = "main"

    @Option(help: "Head ref (branch, tag, or sha).")
    var head: String = "HEAD"

    @Flag(name: .customLong("no-merge-base"), help: "Compare against base directly instead of the merge-base of base and head.")
    var noMergeBase = false

    @Option(help: "Path to a reviewmap.yml (default: reviewmap.yml at the head of the repo, if present).")
    var config: String?

    @Option(name: .shortAndLong, help: "Output file. Use - for stdout.")
    var output: String = "change-model.json"

    @Option(help: "Maximum references kept per edge.")
    var maxRefs: Int = 50

    @Flag(help: "Evaluate Package.swift with `swift package dump-package` instead of parsing it. More exact for computed manifests, but it compiles and runs the manifest code.")
    var dumpPackage = false

    @Flag(help: "Print a short summary to stderr.")
    var summary = false

    @Flag(help: "After writing the model, serve it in the browser viewer and open it.")
    var view = false

    @Option(help: "Port for the viewer server (with --view).")
    var port: Int = 5173

    func validate() throws {
        if view && output == "-" {
            throw ValidationError("--view needs a file, not stdout.")
        }
    }

    func run() throws {
        let start = Date()
        let opts = AnalyzeOptions(repo: repo, base: base, head: head, useMergeBase: !noMergeBase,
                                  configPath: config, maxRefsPerEdge: maxRefs, dumpPackage: dumpPackage)
        let model = try Analyzer.run(opts) { msg in
            FileHandle.standardError.write(Data((msg + "\n").utf8))
        }
        let data = try ChangeModelIO.encode(model)
        if output == "-" {
            FileHandle.standardOutput.write(data)
        } else {
            try data.write(to: URL(fileURLWithPath: output))
        }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
        var lines = ["Wrote \(output == "-" ? "stdout" : output) in \(elapsed)."]
        if summary {
            lines += ChangeModelIO.summary(model)
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        if view {
            try ViewerLauncher.run(model: output, port: port, open: true)
        }
    }
}

ReviewMap.main()
