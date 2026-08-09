import XCTest
@testable import FinderSidebarPanel

/// B8（20260805.3 case61）：内置技能完成卡片必须透出技能自身的完成文案。
/// 此前卡片只有「技能：zip-encrypt · 3.21 秒 结果文件…」，zip-encrypt ok()
/// 里的 AES 解压工具提示在 UI 上不可见（CLI 回显有、AX 树没有）。
final class LocalSkillReplyTests: XCTestCase {
    func testCompletionReplySurfacesSkillOkMessage() {
        let aesNote = "已加密打包 6 项 → /tmp/加密压缩包.zip（AES-256；需用 7-Zip、Keka 等支持 AES 的工具解压）"
        let reply = ChatViewModel.localSkillCompletionReply(
            skill: "zip-encrypt",
            elapsed: 3.214,
            outputs: ["/tmp/加密压缩包.zip"],
            details: "  " + aesNote + "\n"
        )

        XCTAssertTrue(reply.contains("zip-encrypt"))
        XCTAssertTrue(reply.contains("3.21"), "耗时保留两位小数格式")
        XCTAssertTrue(reply.contains("/tmp/加密压缩包.zip"), "结果文件列表必须保留")
        XCTAssertTrue(reply.contains(aesNote), "技能 ok() 文案（含 AES 工具提示）必须透出到卡片")
        XCTAssertFalse(reply.contains("  " + aesNote), "技能说明应去掉首尾空白")
    }

    func testCompletionReplyOmitsNotesSectionWhenDetailsEmpty() {
        for details in [nil, "", "   \n  "] {
            let reply = ChatViewModel.localSkillCompletionReply(
                skill: "img-rotate",
                elapsed: 0.5,
                outputs: ["/tmp/a_旋转.jpg", "/tmp/b_旋转.jpg"],
                details: details
            )
            XCTAssertFalse(reply.contains("技能说明"), "空 details 不应出现说明段")
            XCTAssertFalse(reply.contains("Skill notes"), "空 details 不应出现说明段")
            XCTAssertTrue(reply.contains("/tmp/a_旋转.jpg\n/tmp/b_旋转.jpg"),
                          "多个结果文件按行列出")
        }
    }
}
