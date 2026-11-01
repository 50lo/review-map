import ArgumentParser
import Foundation
import ReviewMapCore

struct ReviewMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reviewmap",
        abstract: "Structural review map for a Swift change.",
        version: Analyzer.version,
        subcommands: [Analyze.self, Annotate.self, ViewCommand.self],
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

    @Flag(name: .customLong("no-llm"), help: "Skip the LLM annotator.")
    var noLLM = false

    @OptionGroup var llm: LLMOptions

    func validate() throws {
        if view && output == "-" {
            throw ValidationError("--view needs a file, not stdout.")
        }
    }

    func run() throws {
        let start = Date()
        let opts = AnalyzeOptions(repo: repo, base: base, head: head, useMergeBase: !noMergeBase,
                                  configPath: config, maxRefsPerEdge: maxRefs, dumpPackage: dumpPackage)
        var model = try Analyzer.run(opts, log: log)
        if !noLLM {
            model = try Annotator.run(model, options: llm.options, log: log)
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

struct LLMOptions: ParsableArguments {
    @Option(name: .customLong("llm"), help: "CLI that runs the LLM annotator: claude or codex.")
    var tool: String = "claude"

    @Option(name: .customLong("llm-model"), help: "Model passed to the CLI (default: the CLI's own default).")
    var model: String?

    @Option(name: .customLong("llm-command"), help: "Executable to run instead of `claude` or `codex`, called with the same arguments.")
    var command: String?

    @Option(name: .customLong("llm-cache"), help: "Cache directory for LLM results (default: ~/.reviewmap/cache).")
    var cache: String?

    @Option(name: .customLong("llm-jobs"), help: "LLM batches run at the same time.")
    var jobs: Int = 4

    @Option(name: .customLong("llm-timeout"), help: "Seconds before one LLM call is stopped.")
    var timeout: Int = 300

    var options: AnnotateOptions {
        AnnotateOptions(tool: tool, command: command, model: model, cacheDir: cache ?? AnnotateOptions.defaultCacheDir,
                        jobs: jobs, timeout: TimeInterval(timeout))
    }
}

struct Annotate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the LLM annotator on an existing change model and write it back."
    )

    @Argument(help: "The change model to annotate.")
    var model: String = "change-model.json"

    @Option(name: .shortAndLong, help: "Output file (default: overwrite the input). Use - for stdout.")
    var output: String?

    @OptionGroup var llm: LLMOptions

    func run() throws {
        let input = try ChangeModelIO.decode(Data(contentsOf: URL(fileURLWithPath: model)))
        let annotated = try Annotator.run(input, options: llm.options, log: log)
        let data = try ChangeModelIO.encode(annotated)
        let out = output ?? model
        if out == "-" {
            FileHandle.standardOutput.write(data)
        } else {
            try data.write(to: URL(fileURLWithPath: out))
            log("Wrote \(out).")
        }
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

ReviewMap.main()
