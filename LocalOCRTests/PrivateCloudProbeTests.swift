import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import LocalOCR

/// 實驗：沒有 Private Cloud Compute 授權時，碰它的 API 會不會讓 App 當掉。平常略過；
/// 「PCC probe」工作流程以 TEST_RUNNER_PCC_PROBE=1 執行，每一步前後印出 [probe]，當掉時看最後一行在哪一步。
@MainActor
final class PrivateCloudProbeTests: XCTestCase {
    func testTouchingPrivateCloudComputeWithoutTheEntitlement() async throws {
        guard ProcessInfo.processInfo.environment["PCC_PROBE"] == "1" else { throw XCTSkip("只在 PCC probe 工作流程執行") }
        XCTAssertFalse(JournalAI.isEntitled, "還沒有授權")
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("需要 iOS 27") }
        print("[probe] pcc: init")
        let model = PrivateCloudComputeLanguageModel()
        print("[probe] pcc: availability")
        print("[probe] pcc: availability = \(model.availability)")
        print("[probe] pcc: isAvailable = \(model.isAvailable)")
        print("[probe] pcc: quotaUsage")
        print("[probe] pcc: quota limit reached = \(model.quotaUsage.isLimitReached)")
        print("[probe] pcc: session")
        let session = LanguageModelSession(model: model, instructions: "回答一個字")
        print("[probe] pcc: respond")
        do {
            let response = try await session.respond(to: "你好")
            print("[probe] pcc: response \(response.content.prefix(20))")
        } catch {
            print("[probe] pcc: respond threw \(type(of: error)): \(error)")
        }
        print("[probe] pcc: done without crashing")
        #else
        throw XCTSkip("這個 SDK 沒有 Private Cloud Compute")
        #endif
    }
}
