import XCTest

@testable import Claude_Statistics

final class ToolActivityFormatterOperationsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CodexTestPlaceholder.register()
        GeminiTestPlaceholder.register()
    }

    override func tearDown() {
        CodexTestPlaceholder.unregister()
        GeminiTestPlaceholder.unregister()
        super.tearDown()
    }

    // MARK: - shellCommandSummary: xcodebuild

    func test_shellSummary_xcodebuildBuildWithScheme() {
        let summary = ToolActivityFormatter.shellCommandSummary("xcodebuild -scheme MyApp build")
        XCTAssertEqual(summary?.operation, "Building MyApp")
    }

    func test_shellSummary_xcodebuildTestWithScheme() {
        let summary = ToolActivityFormatter.shellCommandSummary("xcodebuild -scheme MyApp test")
        XCTAssertEqual(summary?.operation, "Testing MyApp")
    }

    func test_shellSummary_xcodebuildBuildWithoutScheme() {
        let summary = ToolActivityFormatter.shellCommandSummary("xcodebuild build")
        XCTAssertEqual(summary?.operation, "Building with Xcode")
    }

    func test_shellSummary_xcodebuildTestWithoutScheme() {
        let summary = ToolActivityFormatter.shellCommandSummary("xcodebuild test")
        XCTAssertEqual(summary?.operation, "Running Xcode tests")
    }

    // MARK: - shellCommandSummary: rg / ripgrep

    func test_shellSummary_rgSinglePattern() {
        let summary = ToolActivityFormatter.shellCommandSummary("rg foo")
        XCTAssertEqual(summary?.operation, "Searching: foo")
    }

    func test_shellSummary_rgMultipleEPatterns() {
        let summary = ToolActivityFormatter.shellCommandSummary("rg -e foo -e bar")
        XCTAssertEqual(summary?.operation, "Searching 2 patterns")
    }

    func test_shellSummary_rgNoArgs() {
        let summary = ToolActivityFormatter.shellCommandSummary("rg")
        XCTAssertEqual(summary?.operation, "Searching the workspace")
    }

    func test_shellSummary_ripgrepAliasResolves() {
        let summary = ToolActivityFormatter.shellCommandSummary("ripgrep foo")
        XCTAssertEqual(summary?.operation, "Searching: foo")
    }

    // MARK: - shellCommandSummary: grep

    func test_shellSummary_grepWithEPattern() {
        let summary = ToolActivityFormatter.shellCommandSummary("grep -e foo file.txt")
        XCTAssertEqual(summary?.operation, "Searching: foo")
    }

    func test_shellSummary_grepMultipleEPatterns() {
        let summary = ToolActivityFormatter.shellCommandSummary("grep -e foo -e bar")
        XCTAssertEqual(summary?.operation, "Searching 2 patterns")
    }

    func test_shellSummary_grepRegexpEqForm() {
        let summary = ToolActivityFormatter.shellCommandSummary("grep --regexp=foo")
        XCTAssertEqual(summary?.operation, "Searching: foo")
    }

    func test_shellSummary_grepNoPattern() {
        let summary = ToolActivityFormatter.shellCommandSummary("grep")
        XCTAssertEqual(summary?.operation, "Searching files")
    }

    func test_shellSummary_grepAlternationCountsAcrossEPatterns() {
        // -e a -e 'b\|c' — three branches total via shellSearchSummary's sum.
        let summary = ToolActivityFormatter.shellCommandSummary(#"grep -e a -e b\|c"#)
        XCTAssertEqual(summary?.operation, "Searching 3 patterns")
    }

    // MARK: - shellCommandSummary: find

    func test_shellSummary_findSwiftFiles() {
        let summary = ToolActivityFormatter.shellCommandSummary("find . -name '*.swift'")
        XCTAssertEqual(summary?.operation, "Finding Swift files")
    }

    func test_shellSummary_findIname() {
        let summary = ToolActivityFormatter.shellCommandSummary("find . -iname Foo")
        XCTAssertEqual(summary?.operation, "Finding Foo files")
    }

    func test_shellSummary_findNoNameFlag() {
        let summary = ToolActivityFormatter.shellCommandSummary("find .")
        XCTAssertEqual(summary?.operation, "Finding files")
    }

    func test_shellSummary_findJsonExtension() {
        let summary = ToolActivityFormatter.shellCommandSummary("find . -name '*.json'")
        XCTAssertEqual(summary?.operation, "Finding JSON files")
    }

    func test_shellSummary_findShellExtension() {
        let summary = ToolActivityFormatter.shellCommandSummary("find . -name '*.sh'")
        XCTAssertEqual(summary?.operation, "Finding shell scripts")
    }

    func test_shellSummary_findMarkdown() {
        let summary = ToolActivityFormatter.shellCommandSummary("find . -name '*.md'")
        XCTAssertEqual(summary?.operation, "Finding Markdown files")
    }

    // MARK: - shellCommandSummary: read-like (sed/cat/head/tail/less/more/nl)

    func test_shellSummary_catFile() {
        let summary = ToolActivityFormatter.shellCommandSummary("cat foo.txt")
        XCTAssertEqual(summary?.operation, "Reading foo.txt")
    }

    func test_shellSummary_sedNoPath() {
        let summary = ToolActivityFormatter.shellCommandSummary("sed")
        XCTAssertEqual(summary?.operation, "Reading output")
    }

    func test_shellSummary_headWithPath() {
        let summary = ToolActivityFormatter.shellCommandSummary("head /tmp/log.txt")
        XCTAssertEqual(summary?.operation, "Reading log.txt")
    }

    func test_shellSummary_tailNoPath() {
        let summary = ToolActivityFormatter.shellCommandSummary("tail")
        XCTAssertEqual(summary?.operation, "Reading output")
    }

    func test_shellSummary_lessFile() {
        let summary = ToolActivityFormatter.shellCommandSummary("less foo.swift")
        XCTAssertEqual(summary?.operation, "Reading foo.swift")
    }

    func test_shellSummary_moreFile() {
        let summary = ToolActivityFormatter.shellCommandSummary("more foo.swift")
        XCTAssertEqual(summary?.operation, "Reading foo.swift")
    }

    func test_shellSummary_nlFile() {
        let summary = ToolActivityFormatter.shellCommandSummary("nl foo.swift")
        XCTAssertEqual(summary?.operation, "Reading foo.swift")
    }

    // MARK: - shellCommandSummary: ls

    func test_shellSummary_lsWithPath() {
        let summary = ToolActivityFormatter.shellCommandSummary("ls /tmp")
        XCTAssertEqual(summary?.operation, "Listing tmp")
    }

    func test_shellSummary_lsNoArgs() {
        let summary = ToolActivityFormatter.shellCommandSummary("ls")
        XCTAssertEqual(summary?.operation, "Listing files")
    }

    // MARK: - shellCommandSummary: git

    func test_shellSummary_gitStatus() {
        let summary = ToolActivityFormatter.shellCommandSummary("git status")
        XCTAssertEqual(summary?.operation, "Checking git status")
    }

    func test_shellSummary_gitDiff() {
        let summary = ToolActivityFormatter.shellCommandSummary("git diff")
        XCTAssertEqual(summary?.operation, "Reviewing git diff")
    }

    func test_shellSummary_gitShow() {
        let summary = ToolActivityFormatter.shellCommandSummary("git show HEAD")
        XCTAssertEqual(summary?.operation, "Inspecting git commit")
    }

    func test_shellSummary_gitLog() {
        let summary = ToolActivityFormatter.shellCommandSummary("git log --oneline")
        XCTAssertEqual(summary?.operation, "Reading git history")
    }

    func test_shellSummary_gitAdd() {
        let summary = ToolActivityFormatter.shellCommandSummary("git add .")
        XCTAssertEqual(summary?.operation, "Staging changes")
    }

    func test_shellSummary_gitCommit() {
        let summary = ToolActivityFormatter.shellCommandSummary("git commit -m hi")
        XCTAssertEqual(summary?.operation, "Committing changes")
    }

    func test_shellSummary_gitPush() {
        let summary = ToolActivityFormatter.shellCommandSummary("git push origin main")
        XCTAssertEqual(summary?.operation, "Pushing changes")
    }

    func test_shellSummary_gitPull() {
        let summary = ToolActivityFormatter.shellCommandSummary("git pull")
        XCTAssertEqual(summary?.operation, "Pulling changes")
    }

    func test_shellSummary_gitFetch() {
        let summary = ToolActivityFormatter.shellCommandSummary("git fetch origin")
        XCTAssertEqual(summary?.operation, "Fetching git updates")
    }

    func test_shellSummary_gitCheckout() {
        let summary = ToolActivityFormatter.shellCommandSummary("git checkout main")
        XCTAssertEqual(summary?.operation, "Switching git branch")
    }

    func test_shellSummary_gitSwitch() {
        let summary = ToolActivityFormatter.shellCommandSummary("git switch dev")
        XCTAssertEqual(summary?.operation, "Switching git branch")
    }

    func test_shellSummary_gitUnknownSubcommand() {
        let summary = ToolActivityFormatter.shellCommandSummary("git xyz")
        XCTAssertEqual(summary?.operation, "Running git")
    }

    // MARK: - shellCommandSummary: go

    func test_shellSummary_goTest() {
        let summary = ToolActivityFormatter.shellCommandSummary("go test ./...")
        XCTAssertEqual(summary?.operation, "Running Go tests")
    }

    func test_shellSummary_goBuild() {
        let summary = ToolActivityFormatter.shellCommandSummary("go build")
        XCTAssertEqual(summary?.operation, "Building with Go")
    }

    func test_shellSummary_goRun() {
        let summary = ToolActivityFormatter.shellCommandSummary("go run main.go")
        XCTAssertEqual(summary?.operation, "Running Go")
    }

    func test_shellSummary_goModTidy() {
        let summary = ToolActivityFormatter.shellCommandSummary("go mod tidy")
        XCTAssertEqual(summary?.operation, "Updating Go modules")
    }

    func test_shellSummary_goUnknownSubcommand() {
        let summary = ToolActivityFormatter.shellCommandSummary("go vet")
        XCTAssertEqual(summary?.operation, "Running Go")
    }

    // MARK: - shellCommandSummary: swift

    func test_shellSummary_swiftTest() {
        let summary = ToolActivityFormatter.shellCommandSummary("swift test")
        XCTAssertEqual(summary?.operation, "Running Swift tests")
    }

    func test_shellSummary_swiftBuild() {
        let summary = ToolActivityFormatter.shellCommandSummary("swift build")
        XCTAssertEqual(summary?.operation, "Building with Swift")
    }

    // MARK: - shellCommandSummary: npm/pnpm/yarn

    func test_shellSummary_npmInstall() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm install")
        XCTAssertEqual(summary?.operation, "Installing packages")
    }

    func test_shellSummary_yarnTest() {
        let summary = ToolActivityFormatter.shellCommandSummary("yarn test")
        XCTAssertEqual(summary?.operation, "Running package tests")
    }

    func test_shellSummary_npmRunBuildProd() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm run build:prod")
        XCTAssertEqual(summary?.operation, "Running build:prod")
    }

    func test_shellSummary_pnpmBuild() {
        let summary = ToolActivityFormatter.shellCommandSummary("pnpm build")
        XCTAssertEqual(summary?.operation, "Building package")
    }

    func test_shellSummary_npmDev() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm dev")
        XCTAssertEqual(summary?.operation, "Starting dev server")
    }

    func test_shellSummary_npmRunNoScript() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm run")
        XCTAssertEqual(summary?.operation, "Running package script")
    }

    func test_shellSummary_npmShortInstall() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm i")
        XCTAssertEqual(summary?.operation, "Installing packages")
    }

    func test_shellSummary_npmUnknownSubcommand() {
        let summary = ToolActivityFormatter.shellCommandSummary("npm publish")
        XCTAssertEqual(summary?.operation, "Running npm")
    }

    // MARK: - shellCommandSummary: make

    func test_shellSummary_makeWithTarget() {
        let summary = ToolActivityFormatter.shellCommandSummary("make build")
        XCTAssertEqual(summary?.operation, "Running make build")
    }

    func test_shellSummary_makeNoTarget() {
        let summary = ToolActivityFormatter.shellCommandSummary("make")
        XCTAssertEqual(summary?.operation, "Running make")
    }

    // MARK: - shellCommandSummary: docker

    func test_shellSummary_dockerPs() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker ps")
        XCTAssertEqual(summary?.operation, "Checking containers")
    }

    func test_shellSummary_dockerLogs() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker logs")
        XCTAssertEqual(summary?.operation, "Reading container logs")
    }

    func test_shellSummary_dockerBuild() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker build .")
        XCTAssertEqual(summary?.operation, "Building Docker image")
    }

    func test_shellSummary_dockerRun() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker run alpine")
        XCTAssertEqual(summary?.operation, "Running Docker container")
    }

    func test_shellSummary_dockerExec() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker exec my_container bash")
        XCTAssertEqual(summary?.operation, "Running command in container")
    }

    func test_shellSummary_dockerPull() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker pull alpine")
        XCTAssertEqual(summary?.operation, "Pulling Docker image")
    }

    func test_shellSummary_dockerPush() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker push my/image")
        XCTAssertEqual(summary?.operation, "Pushing Docker image")
    }

    func test_shellSummary_dockerInspect() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker inspect my_container")
        XCTAssertEqual(summary?.operation, "Inspecting container")
    }

    func test_shellSummary_dockerUnknownSubcommand() {
        let summary = ToolActivityFormatter.shellCommandSummary("docker network ls")
        XCTAssertEqual(summary?.operation, "Running Docker")
    }

    // MARK: - shellCommandSummary: curl

    func test_shellSummary_curlWithUrl() {
        let summary = ToolActivityFormatter.shellCommandSummary("curl https://x.com")
        XCTAssertEqual(summary?.operation, "Fetching https://x.com")
    }

    func test_shellSummary_curlNoUrl() {
        let summary = ToolActivityFormatter.shellCommandSummary("curl")
        XCTAssertEqual(summary?.operation, "Fetching remote data")
    }

    // MARK: - shellCommandSummary: date / sleep

    func test_shellSummary_date() {
        let summary = ToolActivityFormatter.shellCommandSummary("date")
        XCTAssertEqual(summary?.operation, "Checking the time")
    }

    func test_shellSummary_sleep() {
        let summary = ToolActivityFormatter.shellCommandSummary("sleep 5")
        XCTAssertEqual(summary?.operation, "Waiting")
    }

    // MARK: - shellCommandSummary: scripting interpreters

    func test_shellSummary_pythonScript() {
        let summary = ToolActivityFormatter.shellCommandSummary("python script.py")
        XCTAssertEqual(summary?.operation, "Running script.py")
    }

    func test_shellSummary_python3Script() {
        let summary = ToolActivityFormatter.shellCommandSummary("python3 build/run.py")
        XCTAssertEqual(summary?.operation, "Running run.py")
    }

    func test_shellSummary_nodeNoArgs() {
        let summary = ToolActivityFormatter.shellCommandSummary("node")
        XCTAssertEqual(summary?.operation, "Running node")
    }

    func test_shellSummary_nodeScript() {
        let summary = ToolActivityFormatter.shellCommandSummary("node app.js")
        XCTAssertEqual(summary?.operation, "Running app.js")
    }

    func test_shellSummary_rubyScript() {
        let summary = ToolActivityFormatter.shellCommandSummary("ruby task.rb")
        XCTAssertEqual(summary?.operation, "Running task.rb")
    }

    func test_shellSummary_perlNoArgs() {
        let summary = ToolActivityFormatter.shellCommandSummary("perl")
        XCTAssertEqual(summary?.operation, "Running perl")
    }

    // MARK: - shellCommandSummary: bash/sh/zsh -c recursion

    func test_shellSummary_bashDashCRecursesIntoInnerCommand() {
        let summary = ToolActivityFormatter.shellCommandSummary("bash -c 'git status'")
        XCTAssertEqual(summary?.operation, "Checking git status")
    }

    func test_shellSummary_shDashCRecurses() {
        let summary = ToolActivityFormatter.shellCommandSummary("sh -c 'ls'")
        XCTAssertEqual(summary?.operation, "Listing files")
    }

    func test_shellSummary_zshDashLcRecurses() {
        let summary = ToolActivityFormatter.shellCommandSummary("zsh -lc 'go test'")
        XCTAssertEqual(summary?.operation, "Running Go tests")
    }

    // MARK: - shellCommandSummary: unrecognized executable

    func test_shellSummary_unknownExecutableReturnsNil() {
        let summary = ToolActivityFormatter.shellCommandSummary("random_unknown_cmd foo")
        XCTAssertNil(summary)
    }

    func test_shellSummary_emptyStringReturnsNil() {
        XCTAssertNil(ToolActivityFormatter.shellCommandSummary(""))
    }

    func test_shellSummary_depthLimitReturnsNil() {
        // depth >= 3 short-circuits before any tokenizing.
        XCTAssertNil(ToolActivityFormatter.shellCommandSummary("git status", depth: 3))
    }

    // MARK: - shellCommandSummary: meaningfulShellSegment skips cd/export/etc.

    func test_shellSummary_skipsLeadingCdSegment() {
        let summary = ToolActivityFormatter.shellCommandSummary("cd /tmp && git status")
        XCTAssertEqual(summary?.operation, "Checking git status")
    }

    func test_shellSummary_skipsLeadingExportSegment() {
        let summary = ToolActivityFormatter.shellCommandSummary("export FOO=bar; ls")
        XCTAssertEqual(summary?.operation, "Listing files")
    }

    func test_shellSummary_skipsLeadingSourceSegment() {
        let summary = ToolActivityFormatter.shellCommandSummary("source ~/.zshrc && go build")
        XCTAssertEqual(summary?.operation, "Building with Go")
    }

    func test_shellSummary_skipsLeadingSetSegment() {
        let summary = ToolActivityFormatter.shellCommandSummary("set -e; git diff")
        XCTAssertEqual(summary?.operation, "Reviewing git diff")
    }

    // MARK: - shellCommandSummary: env / inline variable assignments

    func test_shellSummary_stripsEnvPrefix() {
        let summary = ToolActivityFormatter.shellCommandSummary("env GO111MODULE=on go test")
        XCTAssertEqual(summary?.operation, "Running Go tests")
    }

    func test_shellSummary_stripsInlineVariableAssignments() {
        let summary = ToolActivityFormatter.shellCommandSummary("FOO=bar BAR=baz git status")
        XCTAssertEqual(summary?.operation, "Checking git status")
    }

    // MARK: - shellCommandSummary: derived `running` field

    func test_shellSummary_runningFieldIsOperationWithEllipsis() {
        let summary = ToolActivityFormatter.shellCommandSummary("git status")
        XCTAssertEqual(summary?.running, "Checking git status…")
    }

    // MARK: - runningSummary: read

    func test_runningSummary_readWithFilePathContainsFilename() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Read",
            input: ["file_path": .string("foo.swift")]
        )
        XCTAssertTrue(result.contains("foo.swift"), "expected filename in result, got \(result)")
    }

    func test_runningSummary_readWithoutFilePathFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "Read", input: [:])
        XCTAssertFalse(result.contains("foo.swift"))
        XCTAssertFalse(result.isEmpty)
    }

    func test_runningSummary_readMultiplePathsMentionsFirstAndCount() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Read",
            input: ["file_paths": .array([.string("a.swift"), .string("b.swift"), .string("c.swift")])]
        )
        XCTAssertTrue(result.contains("a.swift"))
        XCTAssertTrue(result.contains("2"), "expected '+2 more' style suffix, got \(result)")
    }

    // MARK: - runningSummary: edit / multiedit / write

    func test_runningSummary_editWithFilePath() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Edit",
            input: ["file_path": .string("Bar.swift")]
        )
        XCTAssertTrue(result.contains("Bar.swift"))
    }

    func test_runningSummary_multieditWithFilePath() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "MultiEdit",
            input: ["file_path": .string("Bar.swift")]
        )
        XCTAssertTrue(result.contains("Bar.swift"))
    }

    func test_runningSummary_editWithoutPathFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "Edit", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    func test_runningSummary_writeWithFilePath() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Write",
            input: ["file_path": .string("New.swift")]
        )
        XCTAssertTrue(result.contains("New.swift"))
    }

    // MARK: - runningSummary: bash

    func test_runningSummary_bashWithCommandWrapsShellOperation() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Bash",
            input: ["command": .string("git status")]
        )
        XCTAssertEqual(result, "Bash(Checking git status)")
    }

    func test_runningSummary_bashWithDescriptionOnly() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Bash",
            input: ["description": .string("custom step")]
        )
        XCTAssertEqual(result, "Bash(custom step)")
    }

    func test_runningSummary_bashWithUnrecognizedCommandFallsBackToCommand() {
        // Unknown executable means shellCommandSummary is nil; without a
        // description we surface the raw command verbatim.
        let result = ToolActivityFormatter.runningSummary(
            tool: "Bash",
            input: ["command": .string("random_unknown_cmd foo")]
        )
        XCTAssertEqual(result, "Bash(random_unknown_cmd foo)")
    }

    func test_runningSummary_bashWithNoInput() {
        let result = ToolActivityFormatter.runningSummary(tool: "Bash", input: [:])
        XCTAssertEqual(result, "Bash")
    }

    // MARK: - runningSummary: grep / glob

    func test_runningSummary_grepWithSinglePatternIncludesPattern() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Grep",
            input: ["pattern": .string("foo")]
        )
        XCTAssertTrue(result.contains("foo"))
    }

    func test_runningSummary_grepWithAlternationCollapsesToCount() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Grep",
            input: ["pattern": .string("foo|bar")]
        )
        XCTAssertTrue(result.contains("2"))
        XCTAssertFalse(result.contains("foo|bar"))
    }

    func test_runningSummary_grepWithoutPatternFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "Grep", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - runningSummary: websearch / webfetch

    func test_runningSummary_websearchIncludesQuery() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "WebSearch",
            input: ["query": .string("swift testing")]
        )
        XCTAssertTrue(result.contains("swift testing"))
    }

    func test_runningSummary_websearchWithoutQueryFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "WebSearch", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    func test_runningSummary_webfetchIncludesUrl() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "WebFetch",
            input: ["url": .string("https://example.com")]
        )
        XCTAssertTrue(result.contains("https://example.com"))
    }

    func test_runningSummary_webfetchWithoutUrlFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "WebFetch", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - runningSummary: task / agent

    func test_runningSummary_taskWithDescription() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "Task",
            input: ["description": .string("plan migration")]
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(
            result.contains("plan migration"),
            "expected description in result, got '\(result)'"
        )
    }

    func test_runningSummary_taskWithoutDescriptionFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "Task", input: [:])
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.hasPrefix("Task("))
    }

    // MARK: - runningSummary: alias canonicalisation

    func test_runningSummary_applyPatchCanonicalisesToEdit() {
        // Codex's `apply_patch` is aliased to canonical `edit` by
        // CanonicalToolName.resolve, so it lands in the edit branch and
        // (with no file path) returns the localized fallback for editing.
        let result = ToolActivityFormatter.runningSummary(tool: "apply_patch", input: [:])
        XCTAssertEqual(result, "Edit")
    }

    func test_runningSummary_todowriteFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "TodoWrite", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    func test_runningSummary_enterPlanModeFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "EnterPlanMode", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    func test_runningSummary_exitPlanModeFallsBack() {
        let result = ToolActivityFormatter.runningSummary(tool: "ExitPlanMode", input: [:])
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - runningSummary: unknown tool

    func test_runningSummary_unknownToolWithDetailIncludesDetail() {
        let result = ToolActivityFormatter.runningSummary(
            tool: "MysteryTool",
            input: ["description": .string("doing things")]
        )
        XCTAssertTrue(result.contains("MysteryTool"))
        XCTAssertTrue(result.contains(":"))
        XCTAssertTrue(result.contains("doing things"))
    }

    func test_runningSummary_unknownToolWithNoInputUsesEllipsisFallback() {
        let result = ToolActivityFormatter.runningSummary(tool: "MysteryTool", input: [:])
        XCTAssertEqual(result, "MysteryTool…")
    }

    // MARK: - operationSummary: bash routes through shellCommandSummary

    func test_operationSummary_bashUsesShellCommandSummary() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "Bash",
            input: ["command": .string("git status")]
        )
        XCTAssertEqual(result, "Checking git status")
    }

    func test_operationSummary_bashUnknownCommandFallsThroughToPreferredKeys() {
        // shellCommandSummary nil for "random_unknown_cmd"; bash's preferred
        // key order is description → command, so the raw command surfaces.
        let result = ToolActivityFormatter.operationSummary(
            tool: "Bash",
            input: ["command": .string("random_unknown_cmd foo")]
        )
        XCTAssertEqual(result, "random_unknown_cmd foo")
    }

    func test_operationSummary_bashPrefersDescriptionWhenNoCommand() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "Bash",
            input: ["description": .string("setup step")]
        )
        XCTAssertEqual(result, "setup step")
    }

    // MARK: - operationSummary: non-bash tools route through preferred keys

    func test_operationSummary_readReturnsFilePath() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "Read",
            input: ["file_path": .string("foo.swift")]
        )
        XCTAssertEqual(result, "foo.swift")
    }

    func test_operationSummary_grepReturnsPattern() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "Grep",
            input: ["pattern": .string("needle")]
        )
        XCTAssertEqual(result, "needle")
    }

    func test_operationSummary_websearchReturnsQuery() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "WebSearch",
            input: ["query": .string("swift testing")]
        )
        XCTAssertEqual(result, "swift testing")
    }

    func test_operationSummary_taskReturnsDescription() {
        let result = ToolActivityFormatter.operationSummary(
            tool: "Task",
            input: ["description": .string("plan migration")]
        )
        XCTAssertEqual(result, "plan migration")
    }

    func test_operationSummary_emptyInputReturnsNil() {
        XCTAssertNil(ToolActivityFormatter.operationSummary(tool: "Read", input: [:]))
    }

    func test_operationSummary_truncatesLongValuesAt180Chars() {
        let long = String(repeating: "a", count: 200)
        let result = ToolActivityFormatter.operationSummary(
            tool: "Read",
            input: ["file_path": .string(long)]
        )
        XCTAssertNotNil(result)
        // 180 char prefix + ellipsis → 181 chars including the trailing ….
        XCTAssertEqual(result?.count, 181)
        XCTAssertTrue(result?.hasSuffix("…") == true)
    }
}
