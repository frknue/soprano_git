import AppKit
import Testing
@testable import SopranoGit
@testable import SopranoGitCore

@MainActor
struct WorkspaceChromeTests {
    @Test func theBannerNamesTheOperationStepAndConflicts() {
        #expect(OperationBannerView.text(for: .merge(mergingHead: nil), conflicts: 2) == "Merge in progress · 2 conflicts")
        #expect(OperationBannerView.text(for: .cherryPick(commit: nil), conflicts: 1) == "Cherry-pick in progress · 1 conflict")
        #expect(
            OperationBannerView.text(for: .rebase(headName: "topic", onto: nil, step: 2, total: 5), conflicts: 0)
                == "Rebase in progress · step 2/5 · ready to continue"
        )
    }

    @Test func theStatusBarSummarizesGitErrorsByTheirErrorLine() {
        let message = """
        To origin.git
         ! [rejected]        main -> main (fetch first)
        error: failed to push some refs to 'origin.git'
        """
        #expect(WorkspaceStatusBarView.summaryLine(of: message) == "failed to push some refs to 'origin.git'")
        #expect(WorkspaceStatusBarView.summaryLine(of: "fatal: not a git repository\n") == "not a git repository")
        #expect(WorkspaceStatusBarView.summaryLine(of: "\n  plain words  \n") == "plain words")
    }

    @Test func keycapTextIsCompactForEveryChordKind() throws {
        let cases: [(String, String)] = [
            ("cmd+b", "⌘B"), ("cmd+shift+o", "⇧⌘O"), ("prefix+p", "⌃A P"), ("prefix+shift+s", "⌃A ⇧S"),
            ("j", "J"), ("shift+r", "⇧R"), ("ctrl+tab", "⌃⇥"), ("cmd+enter", "⌘↵"), ("?", "?"), ("cmd+/", "⌘/"),
            ("escape", "Esc"),
        ]
        for (text, expected) in cases {
            #expect(try #require(KeyChord.parse(text)).compactText(prefixKey: "a") == expected)
        }
    }
}
