import XCTest
@testable import SoftLock

final class GuardianMessagesTests: XCTestCase {
    func testSplitMessagesAndMultipleLines() {
        var messages = GuardianMessages()
        XCTAssertEqual(messages.append(Data("dim".utf8)), [])
        XCTAssertEqual(messages.append(Data("med:0\nrestor".utf8)), ["dimmed:0"])
        XCTAssertEqual(messages.append(Data("e-failed\nrestored\n".utf8)), ["restore-failed", "restored"])
        XCTAssertEqual(messages.append(Data()), [])
    }
}
