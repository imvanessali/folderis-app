import XCTest

@testable import FinderSidebarPanel

final class AnnouncementTests: XCTestCase {
    func testNewerBuildNumberWins() {
        XCTAssertTrue(AnnouncementManager.isNewer("20260730.1", than: "20260727.4"))
        XCTAssertTrue(AnnouncementManager.isNewer("20260727.10", than: "20260727.4"))
        XCTAssertFalse(AnnouncementManager.isNewer("20260727.4", than: "20260727.4"))
        XCTAssertFalse(AnnouncementManager.isNewer("20260727.4", than: "20260730.1"))
    }

    func testMissingSegmentsPadWithZero() {
        XCTAssertTrue(AnnouncementManager.isNewer("20260727.1", than: "20260727"))
        XCTAssertFalse(AnnouncementManager.isNewer("20260727", than: "20260727.0"))
    }

    func testNonNumericTreatedAsZero() {
        // 开发构建的版本号异常时宁可亮横幅,也不能因解析崩溃或永远沉默
        XCTAssertTrue(AnnouncementManager.isNewer("20260730.1", than: "dev"))
        XCTAssertFalse(AnnouncementManager.isNewer("dev", than: "20260730.1"))
    }
}
