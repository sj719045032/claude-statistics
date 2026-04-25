import Foundation
import XCTest

@testable import Claude_Statistics

final class ToolActivityFormatterPermissionsTests: XCTestCase {

    // MARK: - Helpers

    private func metaDict(
        _ meta: [(label: String, value: String)]
    ) -> [String: String] {
        var dict: [String: String] = [:]
        for entry in meta {
            dict[entry.label] = entry.value
        }
        return dict
    }

    // MARK: - bash

    func test_permissionPreview_bash_commandPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: ["command": .string("rm -rf /tmp/x")]
        )
        XCTAssertEqual(result.primary, .code("rm -rf /tmp/x"))
        XCTAssertTrue(result.metadata.isEmpty)
        XCTAssertTrue(result.descriptions.isEmpty)
    }

    func test_permissionPreview_bash_runInBackgroundMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: [
                "command": .string("sleep 60"),
                "run_in_background": .bool(true)
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["background"], "yes")
    }

    func test_permissionPreview_bash_runInBackgroundFalseOmitted() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: [
                "command": .string("ls"),
                "run_in_background": .bool(false)
            ]
        )
        XCTAssertNil(metaDict(result.metadata)["background"])
    }

    func test_permissionPreview_bash_timeoutMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: [
                "command": .string("ls"),
                "timeout": .number(5000)
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["timeout"], "5000ms")
    }

    func test_permissionPreview_bash_descriptionInDescriptions() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: [
                "command": .string("rm tmp"),
                "description": .string("cleanup")
            ]
        )
        XCTAssertTrue(result.descriptions.contains("cleanup"))
    }

    func test_permissionPreview_bash_warningInDescriptions() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bash",
            input: [
                "command": .string("rm -rf"),
                "warning": .string("danger")
            ]
        )
        XCTAssertTrue(result.descriptions.contains("danger"))
    }

    // MARK: - read

    func test_permissionPreview_read_filePathPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "read",
            input: ["file_path": .string("/foo.swift")]
        )
        XCTAssertEqual(result.primary, .inline("/foo.swift"))
        XCTAssertTrue(result.metadata.isEmpty)
    }

    func test_permissionPreview_read_offsetMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "read",
            input: [
                "file_path": .string("/foo.swift"),
                "offset": .number(10)
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["offset"], "10")
    }

    func test_permissionPreview_read_limitMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "read",
            input: [
                "file_path": .string("/foo.swift"),
                "limit": .number(50)
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["limit"], "50")
    }

    // MARK: - write

    func test_permissionPreview_write_multilineContentLineCount() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "write",
            input: [
                "file_path": .string("/foo.swift"),
                "content": .string("line1\nline2\nline3")
            ]
        )
        XCTAssertEqual(result.primary, .inline("/foo.swift"))
        XCTAssertEqual(metaDict(result.metadata)["content"], "3 lines")
    }

    func test_permissionPreview_write_singleLineContent() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "write",
            input: [
                "file_path": .string("/foo.swift"),
                "content": .string("single")
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["content"], "1 line")
    }

    // MARK: - edit

    func test_permissionPreview_edit_diffWhenOldAndNewProvided() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "edit",
            input: [
                "file_path": .string("/foo.swift"),
                "old_string": .string("old"),
                "new_string": .string("new")
            ]
        )
        XCTAssertEqual(result.primary, .diff(old: "old", new: "new"))
    }

    func test_permissionPreview_edit_inlinePathWhenNoDiff() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "edit",
            input: ["file_path": .string("/foo.swift")]
        )
        XCTAssertEqual(result.primary, .inline("/foo.swift"))
    }

    func test_permissionPreview_edit_replaceAllMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "edit",
            input: [
                "file_path": .string("/foo.swift"),
                "old_string": .string("a"),
                "new_string": .string("b"),
                "replace_all": .bool(true)
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["replace_all"], "yes")
    }

    func test_permissionPreview_edit_fileMetadataAlwaysPresent() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "edit",
            input: [
                "file_path": .string("/foo.swift"),
                "old_string": .string("a"),
                "new_string": .string("b")
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["file"], "foo.swift")
    }

    // MARK: - multiedit

    func test_permissionPreview_multiedit_threeEdits() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "multiedit",
            input: [
                "file_path": .string("/foo.swift"),
                "edits": .array([
                    .object(["old_string": .string("a"), "new_string": .string("b")]),
                    .object(["old_string": .string("c"), "new_string": .string("d")]),
                    .object(["old_string": .string("e"), "new_string": .string("f")])
                ])
            ]
        )
        XCTAssertEqual(result.primary, .inline("/foo.swift"))
        XCTAssertEqual(metaDict(result.metadata)["edits"], "3 changes")
    }

    func test_permissionPreview_multiedit_singleEdit() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "multiedit",
            input: [
                "file_path": .string("/foo.swift"),
                "edits": .array([
                    .object(["old_string": .string("a"), "new_string": .string("b")])
                ])
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["edits"], "1 change")
    }

    // MARK: - grep

    func test_permissionPreview_grep_patternPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "grep",
            input: ["pattern": .string("TODO")]
        )
        XCTAssertEqual(result.primary, .inline("TODO"))
    }

    func test_permissionPreview_grep_allFlagsMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "grep",
            input: [
                "pattern": .string("TODO"),
                "path": .string("/src"),
                "glob": .string("*.swift"),
                "type": .string("swift"),
                "output_mode": .string("content"),
                "-i": .bool(true),
                "multiline": .bool(true),
                "head_limit": .number(20)
            ]
        )
        let dict = metaDict(result.metadata)
        XCTAssertEqual(dict["path"], "src")
        XCTAssertEqual(dict["glob"], "*.swift")
        XCTAssertEqual(dict["type"], "swift")
        XCTAssertEqual(dict["output_mode"], "content")
        XCTAssertEqual(dict["case"], "insensitive")
        XCTAssertEqual(dict["multiline"], "yes")
        XCTAssertEqual(dict["head_limit"], "20")
    }

    // MARK: - glob

    func test_permissionPreview_glob_patternAndPath() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "glob",
            input: [
                "pattern": .string("**/*.swift"),
                "path": .string("/repo")
            ]
        )
        XCTAssertEqual(result.primary, .inline("**/*.swift"))
        XCTAssertEqual(metaDict(result.metadata)["path"], "repo")
    }

    // MARK: - task / agent

    func test_permissionPreview_task_promptPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "task",
            input: ["prompt": .string("do X")]
        )
        XCTAssertEqual(result.primary, .code("do X"))
    }

    func test_permissionPreview_task_subagentTypeMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "task",
            input: [
                "prompt": .string("do X"),
                "subagent_type": .string("code-review")
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["agent"], "code-review")
    }

    func test_permissionPreview_agent_aliasBehavesLikeTask() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "agent",
            input: ["prompt": .string("do Y")]
        )
        XCTAssertEqual(result.primary, .code("do Y"))
    }

    // MARK: - webfetch

    func test_permissionPreview_webfetch_urlPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "webfetch",
            input: ["url": .string("https://x")]
        )
        XCTAssertEqual(result.primary, .inline("https://x"))
    }

    // MARK: - websearch

    func test_permissionPreview_websearch_queryPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "websearch",
            input: ["query": .string("swift macros")]
        )
        XCTAssertEqual(result.primary, .inline("swift macros"))
    }

    func test_permissionPreview_websearch_allowedDomainsMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "websearch",
            input: [
                "query": .string("swift macros"),
                "allowed_domains": .array([.string("apple.com")])
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["allowed"], "apple.com")
    }

    func test_permissionPreview_websearch_blockedDomainsMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "websearch",
            input: [
                "query": .string("swift macros"),
                "blocked_domains": .array([.string("evil.example")])
            ]
        )
        XCTAssertEqual(metaDict(result.metadata)["blocked"], "evil.example")
    }

    // MARK: - todowrite

    func test_permissionPreview_todowrite_completedMarker() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "todowrite",
            input: [
                "todos": .array([
                    .object([
                        "content": .string("buy milk"),
                        "status": .string("completed")
                    ])
                ])
            ]
        )
        XCTAssertEqual(result.primary, .list(["● buy milk"]))
    }

    func test_permissionPreview_todowrite_inProgressMarker() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "todowrite",
            input: [
                "todos": .array([
                    .object([
                        "content": .string("buy milk"),
                        "status": .string("in_progress")
                    ])
                ])
            ]
        )
        XCTAssertEqual(result.primary, .list(["◐ buy milk"]))
    }

    func test_permissionPreview_todowrite_missingStatusMarker() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "todowrite",
            input: [
                "todos": .array([
                    .object(["content": .string("buy milk")])
                ])
            ]
        )
        XCTAssertEqual(result.primary, .list(["◯ buy milk"]))
    }

    func test_permissionPreview_todowrite_emptyTodosNilPrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "todowrite",
            input: ["todos": .array([])]
        )
        XCTAssertNil(result.primary)
    }

    // MARK: - notebookedit

    func test_permissionPreview_notebookedit_newSourceCodePrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "notebookedit",
            input: [
                "new_source": .string("print('hi')"),
                "notebook_path": .string("/nb.ipynb")
            ]
        )
        XCTAssertEqual(result.primary, .code("print('hi')"))
        XCTAssertEqual(metaDict(result.metadata)["notebook"], "nb.ipynb")
    }

    // MARK: - killshell

    func test_permissionPreview_killshell_shellIdMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "killshell",
            input: ["shell_id": .string("abc123")]
        )
        XCTAssertNil(result.primary)
        XCTAssertEqual(metaDict(result.metadata)["shell_id"], "abc123")
    }

    // MARK: - bashoutput

    func test_permissionPreview_bashoutput_bashIdAndFilter() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "bashoutput",
            input: [
                "bash_id": .string("xyz"),
                "filter": .string("error")
            ]
        )
        let dict = metaDict(result.metadata)
        XCTAssertEqual(dict["bash_id"], "xyz")
        XCTAssertEqual(dict["filter"], "error")
    }

    // MARK: - default branch

    func test_permissionPreview_default_singleStringInlinePrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "unknown_tool",
            input: ["foo": .string("bar")]
        )
        XCTAssertEqual(result.primary, .inline("bar"))
    }

    func test_permissionPreview_default_multilineCodePrimary() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "unknown_tool",
            input: ["foo": .string("line1\nline2")]
        )
        // Default-branch primary keeps embedded newlines (render() flattens
        // \n to space for non-path keys, so a normal string key won't trigger
        // .code; pass a path-like key to keep newlines.)
        // Use a path-like key so renderForKey returns the raw text and the
        // primary becomes .code.
        let pathResult = ToolActivityFormatter.permissionPreview(
            tool: "unknown_tool",
            input: ["file_path": .string("/a\n/b")]
        )
        XCTAssertEqual(pathResult.primary, .code("/a\n/b"))
        // For non-path string keys the default branch flattens newlines,
        // producing a single-line .inline primary.
        if case .inline(let text) = result.primary {
            XCTAssertFalse(text.contains("\n"))
        } else {
            XCTFail("expected inline primary, got \(String(describing: result.primary))")
        }
    }

    func test_permissionPreview_default_descriptionKeyGoesToDescriptions() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "unknown_tool",
            input: [
                "foo": .string("bar"),
                "description": .string("explain me")
            ]
        )
        XCTAssertTrue(result.descriptions.contains("explain me"))
        XCTAssertEqual(result.primary, .inline("bar"))
    }

    func test_permissionPreview_default_extraKeysGoToMetadata() {
        let result = ToolActivityFormatter.permissionPreview(
            tool: "unknown_tool",
            input: [
                "alpha": .string("first"),
                "beta": .string("second"),
                "gamma": .string("third")
            ]
        )
        // Keys are sorted alphabetically: alpha=primary, beta and gamma → meta
        XCTAssertEqual(result.primary, .inline("first"))
        let dict = metaDict(result.metadata)
        XCTAssertEqual(dict["beta"], "second")
        XCTAssertEqual(dict["gamma"], "third")
    }

    func test_permissionPreview_default_proseKeysSetMatches() {
        // Each prose key (description/prompt/message/reason/warning/explanation)
        // routes its value into descriptions instead of metadata or primary.
        for key in ["description", "prompt", "message", "reason", "warning", "explanation"] {
            let result = ToolActivityFormatter.permissionPreview(
                tool: "unknown_tool",
                input: [key: .string("note-\(key)")]
            )
            XCTAssertTrue(
                result.descriptions.contains("note-\(key)"),
                "key \(key) should route to descriptions"
            )
            XCTAssertNil(result.primary, "key \(key) should not become primary")
        }
    }

    // MARK: - permissionDetails

    func test_permissionDetails_bash_preservesNewlinesInCommand() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "bash",
            input: ["command": .string("echo hi\necho bye")]
        )
        XCTAssertEqual(details.first, "echo hi\necho bye")
    }

    func test_permissionDetails_bash_appendsDescriptionAndWarning() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "bash",
            input: [
                "command": .string("ls"),
                "description": .string("list dir"),
                "warning": .string("careful")
            ]
        )
        XCTAssertTrue(details.contains("ls"))
        XCTAssertTrue(details.contains("list dir"))
        XCTAssertTrue(details.contains("careful"))
    }

    func test_permissionDetails_read_filePathFirst() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "read",
            input: ["file_path": .string("/foo.swift")]
        )
        XCTAssertEqual(details.first, "/foo.swift")
    }

    func test_permissionDetails_write_pathAndDescription() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "write",
            input: [
                "file_path": .string("/foo.swift"),
                "description": .string("create file")
            ]
        )
        XCTAssertEqual(details, ["/foo.swift", "create file"])
    }

    func test_permissionDetails_edit_pathOnly() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "edit",
            input: ["file_path": .string("/foo.swift")]
        )
        XCTAssertEqual(details, ["/foo.swift"])
    }

    func test_permissionDetails_multiedit_pathAndPrompt() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "multiedit",
            input: [
                "file_path": .string("/foo.swift"),
                "prompt": .string("rename foo")
            ]
        )
        XCTAssertEqual(details, ["/foo.swift", "rename foo"])
    }

    func test_permissionDetails_websearch_queryAndNote() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "websearch",
            input: [
                "query": .string("swift macros"),
                "description": .string("research")
            ]
        )
        XCTAssertEqual(details, ["swift macros", "research"])
    }

    func test_permissionDetails_default_takesFirstThreeKeyValuePairs() {
        let details = ToolActivityFormatter.permissionDetails(
            tool: "unknown_tool",
            input: [
                "alpha": .string("1"),
                "beta": .string("2"),
                "gamma": .string("3"),
                "delta": .string("4")
            ]
        )
        XCTAssertEqual(details.count, 3)
        // Keys sorted alphabetically: alpha, beta, delta, gamma — first three pairs.
        XCTAssertEqual(details[0], "alpha: 1")
        XCTAssertEqual(details[1], "beta: 2")
        XCTAssertEqual(details[2], "delta: 4")
    }

    // MARK: - isEmpty

    func test_isEmpty_allEmptyReturnsTrue() {
        let content = ToolActivityFormatter.PermissionPreviewContent(
            primary: nil,
            metadata: [],
            descriptions: []
        )
        XCTAssertTrue(content.isEmpty)
    }

    func test_isEmpty_withPrimaryReturnsFalse() {
        let content = ToolActivityFormatter.PermissionPreviewContent(
            primary: .inline("x"),
            metadata: [],
            descriptions: []
        )
        XCTAssertFalse(content.isEmpty)
    }

    func test_isEmpty_withMetadataReturnsFalse() {
        let content = ToolActivityFormatter.PermissionPreviewContent(
            primary: nil,
            metadata: [(label: "k", value: "v")],
            descriptions: []
        )
        XCTAssertFalse(content.isEmpty)
    }

    func test_isEmpty_withDescriptionsReturnsFalse() {
        let content = ToolActivityFormatter.PermissionPreviewContent(
            primary: nil,
            metadata: [],
            descriptions: ["note"]
        )
        XCTAssertFalse(content.isEmpty)
    }
}
