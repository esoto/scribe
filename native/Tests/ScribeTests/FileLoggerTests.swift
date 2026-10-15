import XCTest

final class FileLoggerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_appends_one_timestamped_line_per_message() throws {
        let url = try tempDir().appendingPathComponent("scribe.log")
        let logger = FileLogger(fileURL: url)
        logger.log("hello")
        logger.log("world")
        logger.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" hello"))
        XCTAssertTrue(lines[1].hasSuffix(" world"))
    }

    func test_does_not_rotate_below_the_limit() throws {
        let url = try tempDir().appendingPathComponent("scribe.log")
        let logger = FileLogger(fileURL: url, maxBytes: 10_000)
        for i in 0..<5 { logger.log("line \(i)") }
        logger.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 5)
    }

    func test_rotates_past_the_limit_and_keeps_exactly_one_previous_file() throws {
        let url = try tempDir().appendingPathComponent("scribe.log")
        let logger = FileLogger(fileURL: url, maxBytes: 100)
        for i in 0..<10 { logger.log("line \(i) ........................................") }
        logger.flush()
        let previous = url.appendingPathExtension("1")
        let current = try String(contentsOf: url, encoding: .utf8)
        let kept = try String(contentsOf: previous, encoding: .utf8)
        XCTAssertTrue(current.contains("line 9"))                 // newest line is in the live file
        XCTAssertFalse(kept.isEmpty)                              // one previous file retained
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("2").path))
        XCTAssertLessThan(current.utf8.count, 100 + 120)          // at most one line past the limit
    }

    func test_expires_failed_audio_older_than_seven_days() throws {
        let dir = try tempDir()
        let wav = dir.appendingPathComponent("last_failed.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        let eightDaysAgo = Date(timeIntervalSinceNow: -8 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: wav.path)
        FileLogger.expireFailedAudio(in: dir, olderThanDays: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }

    func test_keeps_recent_failed_audio() throws {
        let dir = try tempDir()
        let wav = dir.appendingPathComponent("last_failed.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        FileLogger.expireFailedAudio(in: dir, olderThanDays: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func test_expiry_touches_only_last_failed_wav() throws {
        let dir = try tempDir()
        let sibling = dir.appendingPathComponent("scribe.log")
        try Data("old log".utf8).write(to: sibling)
        let eightDaysAgo = Date(timeIntervalSinceNow: -8 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: sibling.path)
        FileLogger.expireFailedAudio(in: dir, olderThanDays: 7)   // no last_failed.wav present: must not throw
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func test_recreates_a_log_deleted_while_running() throws {
        let url = try tempDir().appendingPathComponent("scribe.log")
        let logger = FileLogger(fileURL: url)
        logger.log("before")
        logger.flush()
        try FileManager.default.removeItem(at: url)
        logger.log("after delete")
        logger.flush()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix(" after delete\n"))
    }
}
