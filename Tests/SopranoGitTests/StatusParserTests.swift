import AppKit
import Testing
@testable import SopranoGitCore

struct StatusParserTests {
    private let oid = String(repeating: "a", count: 40)
    private let zero = String(repeating: "0", count: 40)

    private func data(_ records: [String]) -> Data {
        Data(records.map { $0 + "\0" }.joined().utf8)
    }

    @Test func ordinaryRecordsSplitIntoStagedAndUnstagedSides() {
        let output = data([
            "# branch.oid \(oid)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 \(oid) \(oid) README.md",
            "1 MM N... 100644 100644 100644 \(oid) \(oid) docs/guide.md",
            "1 .M N... 100644 100644 100644 \(oid) \(oid) src/main.txt",
            "1 A. N... 000000 100644 100644 \(zero) \(oid) src/new file.txt",
            "1 .D N... 100644 100644 000000 \(oid) \(oid) gone.txt",
            "1 D. N... 100644 000000 000000 \(oid) \(zero) staged-delete.txt",
            "1 .T N... 100644 100644 120000 \(oid) \(oid) link",
            "1 .A N... 000000 000000 100644 \(zero) \(zero) intent.txt",
        ])
        let entries = StatusParser.parseEntries(output)
        #expect(entries == [
            StatusEntry(path: "README.md", staged: .modified),
            StatusEntry(path: "docs/guide.md", staged: .modified, unstaged: .modified),
            StatusEntry(path: "src/main.txt", unstaged: .modified),
            StatusEntry(path: "src/new file.txt", staged: .added),
            StatusEntry(path: "gone.txt", unstaged: .deleted),
            StatusEntry(path: "staged-delete.txt", staged: .deleted),
            StatusEntry(path: "link", unstaged: .typeChanged),
            StatusEntry(path: "intent.txt", unstaged: .added),
        ])
    }

    @Test func renameRecordsTakeTheirSourceFromTheNextField() {
        let output = data([
            "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 src/helpers.txt",
            "src/util.txt",
            "2 RM N... 100644 100644 100644 \(oid) \(oid) R087 docs/Über Notizen/naïve file.md",
            "docs/old name.md",
            "2 C. N... 100644 100644 100644 \(oid) \(oid) C100 copy.txt",
            "original.txt",
            "? after-rename.txt",
        ])
        #expect(StatusParser.parseEntries(output) == [
            StatusEntry(path: "src/helpers.txt", oldPath: "src/util.txt", staged: .renamed),
            StatusEntry(path: "docs/Über Notizen/naïve file.md", oldPath: "docs/old name.md", staged: .renamed, unstaged: .modified),
            StatusEntry(path: "copy.txt", oldPath: "original.txt", staged: .copied),
            StatusEntry(path: "after-rename.txt", unstaged: .untracked),
        ])
    }

    @Test func everyConflictCodeBecomesItsConflictKind() {
        let codes = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]
        let output = data(codes.map { "u \($0) N... 100644 100644 100644 100644 \(oid) \(oid) \(oid) conflict-\($0).txt" })
        let entries = StatusParser.parseEntries(output)
        #expect(entries.map(\.conflict) == [.bothModified, .bothAdded, .bothDeleted, .addedByUs, .addedByThem, .deletedByUs, .deletedByThem])
        #expect(entries.map(\.path) == codes.map { "conflict-\($0).txt" })
        #expect(entries.allSatisfy { $0.staged == nil && $0.unstaged == nil })
    }

    @Test func untrackedAndIgnoredRecordsAreHandled() {
        let output = data(["? untracked dir/inner file.txt", "! ignored.log", "? a b"])
        #expect(StatusParser.parseEntries(output) == [
            StatusEntry(path: "untracked dir/inner file.txt", unstaged: .untracked),
            StatusEntry(path: "a b", unstaged: .untracked),
        ])
    }

    @Test func emptyOutputHasNoEntries() {
        #expect(StatusParser.parseEntries(Data()).isEmpty)
        #expect(StatusParser.parseEntries(data(["# branch.oid (initial)", "# branch.head main"])).isEmpty)
    }

    @Test func pausedOperationsAreReadFromTheGitDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sg-op-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            let url = directory.appendingPathComponent(name)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(StatusParser.operation(in: directory) == nil)

        try write("MERGE_HEAD", "\(oid)\n")
        #expect(StatusParser.operation(in: directory) == .merge(mergingHead: oid))
        try fileManager.removeItem(at: directory.appendingPathComponent("MERGE_HEAD"))

        try write("CHERRY_PICK_HEAD", "\(oid)\n")
        #expect(StatusParser.operation(in: directory) == .cherryPick(commit: oid))
        try fileManager.removeItem(at: directory.appendingPathComponent("CHERRY_PICK_HEAD"))

        try write("REVERT_HEAD", "\(oid)\n")
        #expect(StatusParser.operation(in: directory) == .revert(commit: oid))
        try fileManager.removeItem(at: directory.appendingPathComponent("REVERT_HEAD"))

        try write("rebase-apply/head-name", "refs/heads/topic\n")
        try write("rebase-apply/onto", "\(oid)\n")
        try write("rebase-apply/next", "2\n")
        try write("rebase-apply/last", "5\n")
        #expect(StatusParser.operation(in: directory) == .rebase(headName: "topic", onto: oid, step: 2, total: 5))
        try write("rebase-apply/applying", "")
        #expect(StatusParser.operation(in: directory) == nil)
        try fileManager.removeItem(at: directory.appendingPathComponent("rebase-apply"))

        try write("rebase-merge/head-name", "detached HEAD\n")
        try write("rebase-merge/onto", "\(oid)\n")
        try write("rebase-merge/msgnum", "1\n")
        try write("rebase-merge/end", "3\n")
        try write("CHERRY_PICK_HEAD", "\(oid)\n")
        #expect(StatusParser.operation(in: directory) == .rebase(headName: nil, onto: oid, step: 1, total: 3))
    }
}
