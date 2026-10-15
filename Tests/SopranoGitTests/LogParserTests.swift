import AppKit
import Testing
@testable import SopranoGitCore

struct LogParserTests {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)
    private let c = String(repeating: "c", count: 40)
    private let d = String(repeating: "d", count: 64)

    private func record(_ fields: [String]) -> String {
        fields.joined(separator: "\u{1F}")
    }

    @Test func commitsParseMergeRegularAndRootRecords() {
        let output = Data([
            record([a, "\(b) \(c)", "Ada Lovelace", "ada@example.com", "1700007200", "Grace Hopper", "grace@example.com", "1700010800", "Merge branch 'feature/merged'"]),
            record([b, c, "Ünïcödé Name", "u@example.com", "1700003600", "Ünïcödé Name", "u@example.com", "1700003600", "Subject with \u{1F} separator"]),
            record([c, "", "Root", "root@example.com", "1700000000", "Root", "root@example.com", "1700000000", ""]),
        ].joined(separator: "\0").utf8)
        let commits = LogParser.parseCommits(output)
        #expect(commits.count == 3)
        #expect(commits[0] == Commit(
            id: a, parents: [b, c],
            author: Signature(name: "Ada Lovelace", email: "ada@example.com", date: Date(timeIntervalSince1970: 1_700_007_200)),
            committer: Signature(name: "Grace Hopper", email: "grace@example.com", date: Date(timeIntervalSince1970: 1_700_010_800)),
            summary: "Merge branch 'feature/merged'"
        ))
        #expect(commits[0].isMerge)
        #expect(commits[1].parents == [c])
        #expect(commits[1].author.name == "Ünïcödé Name")
        #expect(commits[1].summary == "Subject with \u{1F} separator")
        #expect(commits[2].parents.isEmpty)
        #expect(commits[2].summary == "")
    }

    @Test func sha256IdsParse() {
        let output = Data(record([d, "", "A", "a@x", "1", "A", "a@x", "1", "s"]).utf8)
        #expect(LogParser.parseCommits(output).first?.id == d)
        #expect(LogParser.parseCommits(output).first?.shortID == String(d.prefix(7)))
    }

    @Test func emptyOutputHasNoCommits() {
        #expect(LogParser.parseCommits(Data()).isEmpty)
    }

    @Test func detailKeepsTheFullMessageAndBodyDropsTheSubjectParagraph() throws {
        let message = "Subject line\n\nFirst body paragraph\nwith two lines.\n\nSecond paragraph.\n\n"
        let output = Data((record([a, b, "A", "a@x", "1", "C", "c@x", "2", "Subject line", message]) + "\0").utf8)
        let detail = try #require(LogParser.parseDetail(output))
        #expect(detail.commit.id == a)
        #expect(detail.message == message)
        #expect(LogParser.body(ofMessage: detail.message) == "First body paragraph\nwith two lines.\n\nSecond paragraph.")
    }

    @Test func bodyOfASubjectOnlyMessageIsEmpty() {
        #expect(LogParser.body(ofMessage: "Only a subject\n") == "")
        #expect(LogParser.body(ofMessage: "Wrapped subject\ncontinues here\n\nBody") == "Body")
        #expect(LogParser.body(ofMessage: "Subject\r\n\r\nWindows body\r\n") == "Windows body")
    }

    @Test func stashListRecordsBecomeIndexedStashesWithTheirBase() {
        let output = Data([
            record([a, "\(b) \(c) \(d)", "1700020000", "On main: Newer stash with untracked file"]),
            record([c, "\(b) \(a)", "1700010000", "WIP on main: 1234567 Older subject"]),
        ].joined(separator: "\0").utf8)
        let stashes = LogParser.parseStashes(output)
        #expect(stashes == [
            Stash(index: 0, id: a, base: b, message: "On main: Newer stash with untracked file", date: Date(timeIntervalSince1970: 1_700_020_000)),
            Stash(index: 1, id: c, base: b, message: "WIP on main: 1234567 Older subject", date: Date(timeIntervalSince1970: 1_700_010_000)),
        ])
        #expect(stashes[1].reference == "stash@{1}")
    }
}
