import XCTest
@testable import SatsumaCore

/// Every wheel must show the same segments, in the same order, as the Windows app.
/// Tests/Fixtures/windows-wheels.json was recorded with `Satsuma.exe --list` on a PC with Office installed,
/// so the Mac side runs with every optional engine switched on.
final class CatalogParityTests: XCTestCase {
    func testWheelsMatchWindows() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/windows-wheels.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 150)

        Engines.force("all")
        defer { Engines.force("auto") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var failures: [String] = []
        for c in cases {
            let names = c["files"] as? [String] ?? []
            let paths = names.map { name -> String in
                let p = dir.appendingPathComponent(name).path
                if name == "Project" || name == "Other" { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
                else if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: Data()) }
                return p
            }
            for kind in WheelKind.allCases {
                let content = Catalog.build(kind, paths)
                let labels = content.items.map(\.label)
                let expected = c[kind.rawValue] as? [String] ?? []
                if labels != expected {
                    failures.append("\(names.joined(separator: " + ")) \(kind.rawValue): Mac \(labels), Windows \(expected)")
                }
                let hub = "\(content.hubCaption) | \(content.hubTitle)"
                if let exp = c[kind.rawValue + "Hub"] as? String, hub != exp {
                    failures.append("\(names.joined(separator: " + ")) \(kind.rawValue) hub: Mac \"\(hub)\", Windows \"\(exp)\"")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) differences:\n" + failures.joined(separator: "\n"))
    }

    func testHumanSize() {
        XCTAssertEqual(FileKinds.humanSize(0), "0 B")
        XCTAssertEqual(FileKinds.humanSize(999), "999 B")
        XCTAssertEqual(FileKinds.humanSize(1000), "1 KB")
        XCTAssertEqual(FileKinds.humanSize(2_400_000), "2.4 MB")
        XCTAssertEqual(FileKinds.humanSize(148_000_000), "148 MB")
        XCTAssertEqual(FileKinds.humanSize(31_000_000), "31 MB")
    }

    func testExtensions() {
        XCTAssertEqual(FileKinds.ext("/a/backup.tar.gz"), "tgz")
        XCTAssertEqual(FileKinds.baseName("/a/backup.tar.gz"), "backup")
        XCTAssertEqual(FileKinds.ext("/a/Photo.JPG"), "jpg")
        XCTAssertEqual(FileKinds.baseName("/a/notes.txt.gz"), "notes.txt")
        XCTAssertEqual(FileKinds.kindOf("/a/clip.mov"), .video)
    }

    func testUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-names-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertEqual(OutputPaths.unique(dir: dir, baseName: "photo", ext: "png"), dir + "/photo.png")
        FileManager.default.createFile(atPath: dir + "/photo.png", contents: Data())
        XCTAssertEqual(OutputPaths.unique(dir: dir, baseName: "photo", ext: "png"), dir + "/photo 2.png")
        FileManager.default.createFile(atPath: dir + "/photo 2.png", contents: Data())
        XCTAssertEqual(OutputPaths.unique(dir: dir, baseName: "photo", ext: ".png"), dir + "/photo 3.png")
    }

    func testHitTesting() {
        let L = WheelLayout(scale: 1, showHints: true)
        XCTAssertEqual(L.hitTest(L.cx, L.cy, 8), -1)
        XCTAssertEqual(L.hitTest(L.cx, L.cy - (L.r + L.rIn) / 2, 8), 0) // 12 o'clock
        XCTAssertEqual(L.hitTest(L.cx + (L.r + L.rIn) / 2, L.cy, 4), 1) // 3 o'clock is segment 1 of 4
        XCTAssertEqual(L.hitTest(L.cx + L.hitRadius + 1, L.cy, 8), -2)
        XCTAssertEqual(L.r, 150)
        XCTAssertEqual(L.rIn, 64)
        XCTAssertEqual(L.rHub, 56)
    }

    func testCsvRoundTrip() {
        let rows = SheetConverter.readDelimited("a,b\n\"x, y\",\"he said \"\"hi\"\"\"\n", nil)
        XCTAssertEqual(rows, [["a", "b"], ["x, y", "he said \"hi\""]])
    }

    func testSubtitleTimes() {
        XCTAssertEqual(SubtitleConverter.seconds("01:02:03,500"), 3723.5, accuracy: 0.001)
        XCTAssertEqual(SubtitleConverter.fmt(3723.5, ","), "01:02:03,500")
    }

    func testMarkdownModel() {
        let doc = DocReaders.markdown("# Title\n\nSome **bold** text.\n\n- one\n- two\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        let types = doc.blocks.map(\.type)
        XCTAssertEqual(types.first, .heading)
        XCTAssertTrue(types.contains(.listItem))
        XCTAssertTrue(types.contains(.table))
        XCTAssertTrue(doc.blocks.contains { b in b.inlines.contains { $0.bold && $0.text == "bold" } })
    }
}
