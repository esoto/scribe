import XCTest

final class PasteCoreTests: XCTestCase {
    // MARK: - Test Doubles

    class FakePasteboard: PasteboardLike {
        private var value: String?
        private var count: Int = 1

        init(initial: String? = "old stuff") {
            self.value = initial
        }

        func get() -> String? {
            return value
        }

        func set(_ s: String) {
            value = s
            count += 1
        }

        func changeCount() -> Int {
            return count
        }
    }

    class Scheduler {
        var jobs: [(delay: Double, job: () -> Void)] = []

        func schedule(_ delay: Double, _ job: @escaping () -> Void) {
            jobs.append((delay: delay, job: job))
        }

        func fire() {
            for (_, job) in jobs {
                job()
            }
        }
    }

    // MARK: - Tests

    func test_paste_sets_posts_and_restores() throws {
        let pb = FakePasteboard()
        let sched = Scheduler()
        var posts: [Int] = []

        let paster = Paster(
            pasteboard: pb,
            postCmdV: { posts.append(1) },
            schedule: sched.schedule,
            restoreDelay: 2.0
        )

        try paster.paste("nuevo texto")

        XCTAssertEqual(pb.get(), "nuevo texto")
        XCTAssertEqual(posts, [1])
        XCTAssertEqual(sched.jobs.count, 1)
        XCTAssertEqual(sched.jobs[0].delay, 2.0)

        sched.fire()
        XCTAssertEqual(pb.get(), "old stuff")
    }

    func test_restore_skipped_if_user_copied_meanwhile() throws {
        let pb = FakePasteboard()
        let sched = Scheduler()

        let paster = Paster(
            pasteboard: pb,
            postCmdV: {},
            schedule: sched.schedule,
            restoreDelay: 2.0
        )

        try paster.paste("nuevo")
        pb.set("user copied this")
        sched.fire()

        XCTAssertEqual(pb.get(), "user copied this")
    }

    func test_empty_clipboard_no_restore_scheduled() throws {
        let pb = FakePasteboard(initial: nil)
        let sched = Scheduler()

        let paster = Paster(
            pasteboard: pb,
            postCmdV: {},
            schedule: sched.schedule,
            restoreDelay: 2.0
        )

        try paster.paste("hola")
        XCTAssertEqual(sched.jobs.count, 0)
    }

    func test_post_failure_raises_and_keeps_text_on_clipboard() throws {
        let pb = FakePasteboard()
        let sched = Scheduler()

        let paster = Paster(
            pasteboard: pb,
            postCmdV: {
                let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "secure input"])
                throw error
            },
            schedule: sched.schedule,
            restoreDelay: 2.0
        )

        XCTAssertThrowsError(try paster.paste("texto")) { error in
            XCTAssertTrue(error is PasteError)
            if let pasteError = error as? PasteError {
                XCTAssertTrue(pasteError.message.contains("secure input"))
            }
        }

        XCTAssertEqual(pb.get(), "texto")
        XCTAssertEqual(sched.jobs.count, 0)
    }
}
