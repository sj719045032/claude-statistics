import XCTest

@testable import Claude_Statistics

final class DisplayTextClassifierTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GeminiTestPlaceholder.register()
        CodexTestPlaceholder.register()
    }

    override func tearDown() {
        GeminiTestPlaceholder.unregister()
        CodexTestPlaceholder.unregister()
        super.tearDown()
    }

    // MARK: - isNoiseValue

    // Computed (not `static let`) so it's evaluated after `setUp`
    // populates the Gemini placeholder. Reading the descriptor at
    // class-load time would lock in the Claude fallback.
    private var geminiNoisePrefixes: [String] {
        ProviderKind.gemini.descriptor.notchNoisePrefixes
    }

    func test_isNoiseValue_genericTokens() {
        for raw in ["true", "false", "null", "nil", "text", "---", "--", "...", "…", "TRUE", "  Null  "] {
            XCTAssertTrue(
                DisplayTextClassifier.isNoiseValue(raw),
                "expected '\(raw)' to be noise"
            )
        }
    }

    func test_isNoiseValue_pureSymbolsAreNoise() {
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue("***"))
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue("???"))
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue("===="))
    }

    func test_isNoiseValue_realTextIsNotNoise() {
        XCTAssertFalse(DisplayTextClassifier.isNoiseValue("hello world"))
        XCTAssertFalse(DisplayTextClassifier.isNoiseValue("file.swift"))
    }

    func test_isNoiseValue_jsonBlobAlwaysNoise() {
        let blob = #"{"foo": "bar", "baz": 42}"#
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue(blob))
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue(blob, noisePrefixes: self.geminiNoisePrefixes))
    }

    func test_isNoiseValue_geminiShellMetadataPrefixes() {
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue("Process group pgid: 12345", noisePrefixes: self.geminiNoisePrefixes))
        XCTAssertTrue(DisplayTextClassifier.isNoiseValue("Background PIDs: 4321, 5678", noisePrefixes: self.geminiNoisePrefixes))
    }

    func test_isNoiseValue_geminiPrefixesAreFineForOtherModes() {
        XCTAssertFalse(DisplayTextClassifier.isNoiseValue("Process group pgid: 1"))
        XCTAssertFalse(DisplayTextClassifier.isNoiseValue("Background PIDs: 1"))
    }

    // MARK: - isJsonLikeBlob

    func test_isJsonLikeBlob_shortBlobRejected() {
        XCTAssertFalse(DisplayTextClassifier.isJsonLikeBlob(#"{"a":1}"#))
    }

    func test_isJsonLikeBlob_longObjectAccepted() {
        XCTAssertTrue(DisplayTextClassifier.isJsonLikeBlob(#"{"foo":"bar","x":1}"#))
    }

    func test_isJsonLikeBlob_longArrayAccepted() {
        XCTAssertTrue(DisplayTextClassifier.isJsonLikeBlob(#"[{"foo":"bar","x":1}]"#))
    }

    func test_isJsonLikeBlob_textWithoutColonQuoteRejected() {
        XCTAssertFalse(DisplayTextClassifier.isJsonLikeBlob("[this is sixteen plus]"))
    }

    func test_isJsonLikeBlob_nonBraceOrBracketRejected() {
        XCTAssertFalse(DisplayTextClassifier.isJsonLikeBlob(#"hello "key": "value""#))
    }

    // MARK: - isInternalMarkupValue

    func test_isInternalMarkup_taskNotificationTag() {
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("<task-notification>foo</task-notification>"))
    }

    func test_isInternalMarkup_systemReminder() {
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("<system-reminder>blah</system-reminder>"))
    }

    func test_isInternalMarkup_localCommandCaveat() {
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("<local-command-caveat>x</local-command-caveat>"))
    }

    func test_isInternalMarkup_standaloneTag() {
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("<my-tag>"))
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("</my-tag>"))
        XCTAssertTrue(DisplayTextClassifier.isInternalMarkupValue("<<my-tag>>"))
    }

    func test_isInternalMarkup_nonMarkupTextIsKept() {
        XCTAssertFalse(DisplayTextClassifier.isInternalMarkupValue("hello"))
        XCTAssertFalse(DisplayTextClassifier.isInternalMarkupValue("a < b"), "stray < without closing > is not markup")
    }

    func test_isInternalMarkup_unrelatedTagIsKept() {
        XCTAssertFalse(
            DisplayTextClassifier.isInternalMarkupValue("<p>not internal</p>"),
            "trailing text after a non-internal tag is not flagged"
        )
    }

    // MARK: - isStandaloneInternalTag

    func test_isStandaloneInternalTag_simpleOpen() {
        XCTAssertTrue(DisplayTextClassifier.isStandaloneInternalTag("<foo>"))
    }

    func test_isStandaloneInternalTag_closingSlash() {
        XCTAssertTrue(DisplayTextClassifier.isStandaloneInternalTag("</foo>"))
    }

    func test_isStandaloneInternalTag_doubleAngle() {
        XCTAssertTrue(DisplayTextClassifier.isStandaloneInternalTag("<<foo>>"))
    }

    func test_isStandaloneInternalTag_withAttributes() {
        XCTAssertTrue(DisplayTextClassifier.isStandaloneInternalTag("<foo bar=baz>"))
    }

    func test_isStandaloneInternalTag_dashedName() {
        XCTAssertTrue(DisplayTextClassifier.isStandaloneInternalTag("<task-notification>"))
    }

    func test_isStandaloneInternalTag_textBeforeRejected() {
        XCTAssertFalse(DisplayTextClassifier.isStandaloneInternalTag("hello <foo>"))
    }

    func test_isStandaloneInternalTag_textAfterRejected() {
        XCTAssertFalse(DisplayTextClassifier.isStandaloneInternalTag("<foo> hello"))
    }

    // MARK: - isRawToolLabel

    func test_isRawToolLabel_emptyAlwaysTrue() {
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("", toolName: nil))
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("   ", toolName: "Bash"))
    }

    func test_isRawToolLabel_matchesToolName() {
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("apply_patch", toolName: "apply_patch"))
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("APPLY_PATCH", toolName: "apply_patch"))
    }

    func test_isRawToolLabel_matchesPrettyName() {
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("Command", toolName: "bash"), "pretty(bash) = Command")
        XCTAssertTrue(DisplayTextClassifier.isRawToolLabel("Search", toolName: "grep"), "pretty(grep) = Search")
    }

    func test_isRawToolLabel_genericToolNamesAlwaysFlagged() {
        for raw in ["bash", "read", "write", "edit", "multiedit", "grep", "glob", "task", "agent"] {
            XCTAssertTrue(
                DisplayTextClassifier.isRawToolLabel(raw, toolName: nil),
                "expected '\(raw)' to be flagged as raw tool"
            )
        }
    }

    func test_isRawToolLabel_realDetailIsNotFlagged() {
        XCTAssertFalse(DisplayTextClassifier.isRawToolLabel("Reading foo.txt", toolName: "read"))
        XCTAssertFalse(DisplayTextClassifier.isRawToolLabel("Searching for fooPattern", toolName: "grep"))
    }

    // MARK: - prettyToolName

    func test_prettyToolName_specificMappings() {
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("bash"), "Command")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("read"), "Read")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("write"), "Write")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("edit"), "Edit")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("multiedit"), "Edit")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("grep"), "Search")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("glob"), "Files")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("task"), "Agent")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("agent"), "Agent")
    }

    func test_prettyToolName_webVariants() {
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("websearch"), "Web Search")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("web_search"), "Web Search")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("webfetch"), "Fetch")
    }

    func test_prettyToolName_caseInsensitive() {
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("BASH"), "Command")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("Read"), "Read")
    }

    func test_prettyToolName_unknownIsCapitalized() {
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("apply_patch"), "Apply_patch")
        XCTAssertEqual(DisplayTextClassifier.prettyToolName("foo"), "Foo")
    }

    // MARK: - isGenericProcessingText

    func test_isGenericProcessing_asciiVariants() {
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("Working..."))
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("thinking..."))
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("STARTING..."))
    }

    func test_isGenericProcessing_unicodeEllipsis() {
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("Working…"))
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("Thinking…"))
    }

    func test_isGenericProcessing_realDetailIsNotGeneric() {
        XCTAssertFalse(DisplayTextClassifier.isGenericProcessingText("Reading foo.txt"))
        XCTAssertFalse(DisplayTextClassifier.isGenericProcessingText("Searching for X"))
    }

    func test_isGenericProcessing_isWhitespaceTolerant() {
        XCTAssertTrue(DisplayTextClassifier.isGenericProcessingText("   working...   "))
    }

    // MARK: - isPathLikeText

    func test_isPathLike_absolutePath() {
        XCTAssertTrue(DisplayTextClassifier.isPathLikeText("/usr/local/bin"))
    }

    func test_isPathLike_homePath() {
        XCTAssertTrue(DisplayTextClassifier.isPathLikeText("~/Documents"))
    }

    func test_isPathLike_relativeWithExtension() {
        XCTAssertTrue(DisplayTextClassifier.isPathLikeText("src/foo.swift"))
    }

    func test_isPathLike_relativeWithoutExtensionRejected() {
        XCTAssertFalse(DisplayTextClassifier.isPathLikeText("src/foo"))
    }

    func test_isPathLike_urlRejected() {
        XCTAssertFalse(DisplayTextClassifier.isPathLikeText("https://example.com/foo.swift"))
    }

    func test_isPathLike_plainTextRejected() {
        XCTAssertFalse(DisplayTextClassifier.isPathLikeText("hello world"))
    }

    func test_isPathLike_emptyRejected() {
        XCTAssertFalse(DisplayTextClassifier.isPathLikeText(""))
        XCTAssertFalse(DisplayTextClassifier.isPathLikeText("   "))
    }

    // MARK: - pathBasename

    func test_pathBasename_extractsLastComponent() {
        XCTAssertEqual(DisplayTextClassifier.pathBasename("/usr/local/bin/foo.txt"), "foo.txt")
    }

    func test_pathBasename_expandsTilde() {
        let basename = DisplayTextClassifier.pathBasename("~/foo.txt")
        XCTAssertEqual(basename, "foo.txt")
    }

    func test_pathBasename_returnsNilForNonPath() {
        XCTAssertNil(DisplayTextClassifier.pathBasename("hello"))
        XCTAssertNil(DisplayTextClassifier.pathBasename("https://example.com/foo.swift"))
    }

    // MARK: - isCommandLikeText

    func test_isCommandLike_commonShellPrefixes() {
        for prefix in ["cd ", "git ", "go ", "docker ", "bash ", "python ",
                       "cargo ", "npm ", "pnpm ", "yarn ", "make ", "gh "] {
            XCTAssertTrue(
                DisplayTextClassifier.isCommandLikeText("\(prefix)foo bar"),
                "expected '\(prefix)foo bar' to be command-like"
            )
        }
    }

    func test_isCommandLike_pipelineOrFlagsTriggers() {
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("foo && bar"))
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("ls 2>&1"))
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("ls | grep foo"))
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("foo --bar"))
    }

    func test_isCommandLike_plainTextNotFlagged() {
        XCTAssertFalse(DisplayTextClassifier.isCommandLikeText("hello world"))
        XCTAssertFalse(DisplayTextClassifier.isCommandLikeText("Reading foo.swift"))
    }

    func test_isCommandLike_caseInsensitivePrefixes() {
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("CD /tmp"))
        XCTAssertTrue(DisplayTextClassifier.isCommandLikeText("GIT status"))
    }

    func test_isCommandLike_emptyRejected() {
        XCTAssertFalse(DisplayTextClassifier.isCommandLikeText(""))
        XCTAssertFalse(DisplayTextClassifier.isCommandLikeText("    "))
    }

    // MARK: - isCodeLikeSnippet

    func test_isCodeLike_swiftDeclarationPrefixes() {
        for prefix in ["let ", "var ", "func ", "guard ", "if ", "switch ", "case ",
                       "return ", "private ", "fileprivate ", "internal ", "public ",
                       "struct ", "class ", "enum ", "protocol ", "extension ",
                       "@State ", "@MainActor", "import "] {
            XCTAssertTrue(
                DisplayTextClassifier.isCodeLikeSnippet("\(prefix)foo"),
                "expected '\(prefix)foo' to be code-like"
            )
        }
    }

    func test_isCodeLike_braceLines() {
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("if x {"))
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("}"))
    }

    func test_isCodeLike_assignmentRegex() {
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("foo = bar"))
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("foo.bar = Baz()"))
    }

    func test_isCodeLike_declarationRegex() {
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("let x: Int = 1"))
        XCTAssertTrue(DisplayTextClassifier.isCodeLikeSnippet("guard let x = y else { return }"))
    }

    func test_isCodeLike_plainProseNotFlagged() {
        XCTAssertFalse(DisplayTextClassifier.isCodeLikeSnippet("Reading file.swift"))
        XCTAssertFalse(DisplayTextClassifier.isCodeLikeSnippet("hello world"))
    }

    func test_isCodeLike_punctuationAloneNotFlagged() {
        // Contains ": " but doesn't look like assignment/declaration
        XCTAssertFalse(DisplayTextClassifier.isCodeLikeSnippet("Note: this is fine"))
    }

    func test_isCodeLike_emptyRejected() {
        XCTAssertFalse(DisplayTextClassifier.isCodeLikeSnippet(""))
        XCTAssertFalse(DisplayTextClassifier.isCodeLikeSnippet("   "))
    }

    // MARK: - Provider notch capability defaults

    func test_providerDescriptor_carriesNotchCapabilities() {
        XCTAssertFalse(ProviderKind.claude.descriptor.commandFilteredNotchPreview)
        XCTAssertTrue(ProviderKind.codex.descriptor.commandFilteredNotchPreview)
        XCTAssertTrue(ProviderKind.gemini.descriptor.commandFilteredNotchPreview)

        XCTAssertEqual(ProviderKind.claude.descriptor.notchProcessingHintKey, "notch.operation.thinking")
        XCTAssertEqual(ProviderKind.codex.descriptor.notchProcessingHintKey, "notch.operation.working")
        XCTAssertEqual(ProviderKind.gemini.descriptor.notchProcessingHintKey, "notch.operation.working")

        XCTAssertTrue(ProviderKind.claude.descriptor.notchNoisePrefixes.isEmpty)
        XCTAssertTrue(ProviderKind.codex.descriptor.notchNoisePrefixes.isEmpty)
        XCTAssertEqual(
            Set(ProviderKind.gemini.descriptor.notchNoisePrefixes),
            Set(["process group pgid:", "background pids:"])
        )
    }
}
