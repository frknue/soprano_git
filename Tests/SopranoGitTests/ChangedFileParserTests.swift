import AppKit
import Testing
@testable import SopranoGitCore

struct ChangedFileParserTests {
    private let x = String(repeating: "1", count: 40)
    private let y = String(repeating: "2", count: 40)
    private let z = String(repeating: "0", count: 40)

    @Test func rawAndNumstatRecordsMergeByPath() {
        let fields = [
            ":100644 100644 \(x) \(y) M", "bin.dat",
            ":100644 100644 \(x) \(y) M", "crlf.txt",
            ":100644 000000 \(x) \(z) D", "del.txt",
            ":000000 100644 \(z) \(y) A", "docs/Über Notizen/naïve file.md",
            ":100644 100644 \(x) \(y) R088", "ren.txt", "re named.txt",
            ":120000 100644 \(x) \(y) T", "link",
            "-\t-\tbin.dat",
            "1\t1\tcrlf.txt",
            "0\t1\tdel.txt",
            "3\t0\tdocs/Über Notizen/naïve file.md",
            "1\t0\t", "ren.txt", "re named.txt",
            "1\t1\tlink",
        ]
        let output = Data(fields.map { $0 + "\0" }.joined().utf8)
        #expect(ChangedFileParser.parse(output) == [
            ChangedFile(path: "bin.dat", kind: .modified, additions: nil, deletions: nil),
            ChangedFile(path: "crlf.txt", kind: .modified, additions: 1, deletions: 1),
            ChangedFile(path: "del.txt", kind: .deleted, additions: 0, deletions: 1),
            ChangedFile(path: "docs/Über Notizen/naïve file.md", kind: .added, additions: 3, deletions: 0),
            ChangedFile(path: "re named.txt", oldPath: "ren.txt", kind: .renamed, additions: 1, deletions: 0),
            ChangedFile(path: "link", kind: .typeChanged, additions: 1, deletions: 1),
        ])
    }

    @Test func kindOverrideMarksStashUntrackedFiles() {
        let output = Data(":000000 100644 \(z) \(y) A\0scratch/new.txt\02\t0\tscratch/new.txt\0".utf8)
        #expect(ChangedFileParser.parse(output, kindOverride: .untracked) == [
            ChangedFile(path: "scratch/new.txt", kind: .untracked, additions: 2, deletions: 0),
        ])
    }

    @Test func emptyOutputHasNoFiles() {
        #expect(ChangedFileParser.parse(Data()).isEmpty)
    }
}
