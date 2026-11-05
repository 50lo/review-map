import ArgumentParser
import Foundation
import ReviewMapCore

struct ReviewMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reviewmap",
        abstract: "Structural review map for a code change.",
        discussion: "With no subcommand, `reviewmap` reviews the current branch of the repo in the current directory against main and opens the viewer.",
        version: Analyzer.version,
        subcommands: [Review.self, Analyze.self, Annotate.self, ViewCommand.self],
        defaultSubcommand: Review.self
    )
}

/// What to analyze and how; shared by `review` and `analyze`.
struct AnalyzeArgs: ParsableArguments {
    @Argument(help: "Path to the git repository (any directory inside it).")
    var repo: String = "."

    @Option(help: "Base ref (branch, tag, or sha).")
    var base: String = "main"

    @Option(help: "Head ref (branch, tag, or sha). Default: the current branch.")
    var head: String?

    @Flag(name: .customLong("no-merge-base"), help: "Compare against base directly instead of the merge-base of base and head.")
    var noMergeBase = false

    @Option(help: "Path to a reviewmap.yml (default: reviewmap.yml at the head of the repo, if present).")
    var config: String?

    @Option(name: .shortAndLong, help: "Output file, or - for stdout (default: ~/.reviewmap/models/<repo>/<head>/change-model.json).")
    var output: String?

    @Option(help: "Maximum references kept per edge.")
    var maxRefs: Int = 50

    @Flag(help: "Evaluate Package.swift with `swift package dump-package` instead of parsing it. More exact for computed manifests, but it compiles and runs the manifest code.")
    var dumpPackage = false

    @Flag(help: "Print a short summary to stderr.")
    var summary = false

    @Option(help: "Port for the viewer server.")
    var port: Int = 5173

    @Option(help: ArgumentHelp(ViewerLauncher.editorHelp))
    var editor: String?

    @Flag(name: .customLong("no-llm"), help: "Skip the LLM annotator.")
    var noLLM = false

    @OptionGroup var llm: LLMOptions

    @OptionGroup var indexArgs: IndexArgs

    func run(view: Bool) throws {
        if view && output == "-" {
            throw ValidationError("The viewer needs a file, not stdout.")
        }
        let start = Date()
        let head = self.head ?? Analyzer.currentBranch(repo: repo)
        let output = try self.output ?? ModelPath.default(repo: repo, head: head)
        let opts = AnalyzeOptions(repo: repo, base: base, head: head, useMergeBase: !noMergeBase,
                                  configPath: config, maxRefsPerEdge: maxRefs, dumpPackage: dumpPackage, index: indexArgs.options)
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
            try ViewerLauncher.run(model: output, port: port, open: true, editor: editor)
        }
    }
}

struct Review: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze the change, write change-model.json, and open it in the viewer (the default command)."
    )

    @OptionGroup var args: AnalyzeArgs

    @Flag(inversion: .prefixedNo, help: "Serve the result in the browser viewer and open it.")
    var view = true

    func run() throws {
        try args.run(view: view)
    }
}

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze the change between two git refs and write change-model.json."
    )

    @OptionGroup var args: AnalyzeArgs

    @Flag(help: "After writing the model, serve it in the browser viewer and open it.")
    var view = false

    func run() throws {
        try args.run(view: view)
    }
}

struct IndexArgs: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Resolve references exactly from each language's index instead of by name: a build's index store for Swift, scip-typescript for TypeScript. Indexes base and head once per commit (default: index.enabled in reviewmap.yml).")
    var index: Bool?

    @Option(name: .customLong("index-builder"), help: "Swift: bazel, xcodebuild, or swift (default: bazel for a Bazel workspace with targets, else xcodebuild where it exists, else swift).")
    var builder: String?

    @Option(name: .customLong("index-target"), help: "Swift: Bazel target to build; repeat for several (default: top_level_targets of the repo's rules_xcodeproj rule).")
    var targets: [String] = []

    @Option(name: .customLong("index-project"), help: "Swift: the .xcworkspace, .xcodeproj, or package directory to build, relative to the repo root.")
    var project: String?

    @Option(name: .customLong("index-scheme"), help: "xcodebuild scheme (default: the only one, or the one named after the project).")
    var scheme: String?

    @Option(name: .customLong("index-destination"), help: "xcodebuild destination (default: generic/platform=iOS Simulator).")
    var destination: String?

    @Option(name: .customLong("index-cache"), help: "Directory for built indexes (default: ~/.reviewmap/index).")
    var cache: String?

    @Flag(name: .customLong("rebuild-index"), help: "Build again even when the index of a commit is cached.")
    var rebuild = false

    var options: IndexOptions {
        IndexOptions(enabled: index, builder: builder, project: project, scheme: scheme, destination: destination,
                     targets: targets.isEmpty ? nil : targets,
                     cacheDir: cache ?? IndexOptions.defaultCacheDir, rebuild: rebuild,
                     workingDirectory: FileManager.default.currentDirectoryPath)
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

    @Argument(help: "The change model to annotate (default: the model of the current branch of the repo in the current directory).")
    var model: String?

    @Option(name: .shortAndLong, help: "Output file (default: overwrite the input). Use - for stdout.")
    var output: String?

    @OptionGroup var llm: LLMOptions

    func run() throws {
        let model = try self.model ?? ModelPath.current()
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

/// Where models go when no path is given: outside the target repo, one per repo and head,
/// so reviewed marks and notes (saved next to the model) stay per branch.
enum ModelPath {
    static func `default`(repo: String, head: String) throws -> String {
        let root: String
        do {
            root = try Analyzer.repoRoot(repo: repo)
        } catch {
            throw ValidationError("\(repo == "." ? "The current directory" : repo) is not inside a git repository. Pass a repo or model path.")
        }
        let dir = (AnnotateOptions.home as NSString).appendingPathComponent(".reviewmap/models")
            + "/" + Paths.slug((root as NSString).lastPathComponent) + "/" + Paths.slug(head)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/change-model.json"
    }

    /// The default model of the current branch of the repo in the current directory.
    static func current() throws -> String {
        let path = try `default`(repo: ".", head: Analyzer.currentBranch(repo: "."))
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("No change model at \(path). Run reviewmap first, or pass a model path.")
        }
        return path
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

ReviewMap.main()
