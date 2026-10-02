import XCTest
@testable import LocalOCR
#if canImport(FoundationModels)
import FoundationModels
#endif

final class SmartScanTests: XCTestCase {
    // MARK: - 內建樣板

    func testBuiltInTemplatesAreValid() {
        let ids = ScanTemplate.builtIns.map(\.id)
        XCTAssertEqual(ids, ["receipt", "business_card", "event", "document"])
        XCTAssertTrue(ids.contains(ScanTemplate.fallbackID))
        for template in ScanTemplate.builtIns {
            XCTAssertTrue(ScanTemplate.isValidID(template.id), template.id)
            XCTAssertNoThrow(try JSONValue.parse(template.sampleJSON), template.id)
            guard case .object(let members) = template.sample else { return XCTFail("\(template.id) 的範例應為物件") }
            XCTAssertFalse(members.isEmpty)
            XCTAssertFalse(template.keywords.isEmpty)
        }
    }

    func testTemplateIDValidation() {
        XCTAssertTrue(ScanTemplate.isValidID("receipt"))
        XCTAssertTrue(ScanTemplate.isValidID("custom-1a2b_3"))
        XCTAssertFalse(ScanTemplate.isValidID("Receipt"))
        XCTAssertFalse(ScanTemplate.isValidID("-receipt"))
        XCTAssertFalse(ScanTemplate.isValidID("收據"))
        XCTAssertFalse(ScanTemplate.isValidID(""))
        XCTAssertTrue(ScanTemplate.isValidID(ScanTemplate.makeCustomID()))
    }

    // MARK: - 樣板庫

    @MainActor
    func testLibraryOverridesByPriorityAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let library = TemplateLibrary(fileURL: url)
        XCTAssertEqual(library.all.map(\.id), ScanTemplate.builtIns.map(\.id))

        var serverReceipt = ScanTemplate.builtIns[0]
        serverReceipt.name = "伺服器收據"
        let medicine = ScanTemplate(id: "medicine", name: "藥袋", description: "藥袋", sampleJSON: #"{"drug":""}"#, origin: .server)
        library.replaceServerTemplates([serverReceipt, medicine])
        XCTAssertEqual(library.template(id: "receipt")?.name, "伺服器收據")
        XCTAssertEqual(library.template(id: "receipt")?.origin, .server)
        XCTAssertEqual(library.all.last?.id, "medicine")

        var custom = serverReceipt
        custom.name = "我的收據"
        library.saveCustom(custom)
        XCTAssertEqual(library.template(id: "receipt")?.name, "我的收據")
        XCTAssertEqual(library.template(id: "receipt")?.origin, .custom)

        let reloaded = TemplateLibrary(fileURL: url)
        XCTAssertEqual(reloaded.template(id: "receipt")?.name, "我的收據")
        XCTAssertEqual(reloaded.template(id: "medicine")?.name, "藥袋")

        reloaded.deleteCustom(id: "receipt")
        XCTAssertEqual(reloaded.template(id: "receipt")?.name, "伺服器收據")
    }

    // MARK: - 關鍵字分類

    func testKeywordClassifierPicksBestMatch() {
        let text = "全聯福利中心\n鮮乳 45\n小計 45\n合計 45\n找零 55"
        let result = KeywordClassifier.classify(text: text, among: ScanTemplate.builtIns)
        XCTAssertEqual(result.templateID, "receipt")
        XCTAssertEqual(result.provider, .keywords)
        XCTAssertNotNil(result.confidence)
    }

    func testKeywordClassifierBusinessCard() {
        let text = "王小明\n產品經理\n範例科技股份有限公司\nTel 02-1234-5678\nEmail ming@example.com"
        XCTAssertEqual(KeywordClassifier.classify(text: text, among: ScanTemplate.builtIns).templateID, "business_card")
    }

    func testKeywordClassifierFallsBackToDocument() {
        let result = KeywordClassifier.classify(text: "Lorem ipsum", among: ScanTemplate.builtIns)
        XCTAssertEqual(result.templateID, "document")
        XCTAssertNil(result.confidence)
    }

    func testPipelineFallsBackWhenClassifiersFail() async {
        struct Failing: DocumentClassifier {
            var provider: Classification.Provider { .jev }
            func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
                throw ServerError(status: 503, code: "jev_not_configured", message: "未設定")
            }
        }
        struct Unknown: DocumentClassifier {
            var provider: Classification.Provider { .onDevice }
            func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
                Classification(templateID: "nope", confidence: 1, probabilities: [:], provider: .onDevice)
            }
        }
        let pipeline = ClassifierPipeline(classifiers: [Failing(), Unknown()])
        let (result, failures) = await pipeline.classify(text: "合計 100 發票", among: ScanTemplate.builtIns)
        XCTAssertEqual(result.templateID, "receipt")
        XCTAssertEqual(result.provider, .keywords)
        XCTAssertEqual(failures.count, 2)
    }

    func testClassificationJSONIsOrdered() {
        let classification = Classification(templateID: "receipt", confidence: 0.9, probabilities: ["document": 0.1, "receipt": 0.9], provider: .jev)
        XCTAssertEqual(
            classification.jsonValue.compactString,
            #"{"templateId":"receipt","confidence":0.9,"provider":"jev","probabilities":{"receipt":0.9,"document":0.1}}"#
        )
    }

    // MARK: - 錯誤說明

    func testAIErrorHints() {
        XCTAssertEqual(AIErrorDescriber.hint(for: "exceededContextWindowSize(Context(...))"), "文字太長，超過裝置端模型可處理的長度。")
        XCTAssertEqual(AIErrorDescriber.hint(for: "LanguageModelError.contextSizeExceeded"), "文字太長，超過裝置端模型可處理的長度。")
        XCTAssertEqual(AIErrorDescriber.hint(for: "guardrailViolation(Context(debugDescription: \"x\"))"), "內容觸發了 Apple Intelligence 的安全機制。")
        XCTAssertNil(AIErrorDescriber.hint(for: "unknownError(Context(debugDescription: \"x\"))"))
        XCTAssertNotNil(AIErrorDescriber.hint(for: "unsupportedLanguageOrLocale(...)"))
        XCTAssertNotNil(AIErrorDescriber.hint(for: "assetsUnavailable(...)"))
        XCTAssertNil(AIErrorDescriber.hint(for: "something else"))
    }

    func testAIErrorDescriptionIncludesLocalizedParts() {
        struct Sample: LocalizedError {
            var errorDescription: String? { "生成失敗" }
            var failureReason: String? { "原因" }
            var recoverySuggestion: String? { "建議" }
        }
        XCTAssertEqual(AIErrorDescriber.describe(Sample()), "生成失敗\n原因\n建議")
        XCTAssertEqual(
            StructuredExtractionError.generation("詳細說明").localizedDescription,
            "詳細說明"
        )
    }

    // MARK: - 伺服器格式

    func testNormalizedServerURL() {
        XCTAssertEqual(ServerSettings.normalizedURL("example.up.railway.app/")?.absoluteString, "https://example.up.railway.app")
        XCTAssertEqual(ServerSettings.normalizedURL(" http://localhost:3000 ")?.absoluteString, "http://localhost:3000")
        XCTAssertNil(ServerSettings.normalizedURL(""))
    }

    func testTemplateParsingFromServerKeepsSampleOrder() throws {
        let value = try JSONValue.parse(#"{"id":"medicine","name":"藥袋","description":"藥局藥袋","keywords":["藥","服用"],"sample":{"drug":"普拿疼","dose":"500mg","times":3},"instructions":"","version":4}"#)
        let template = try XCTUnwrap(ServerClient.template(from: value))
        XCTAssertEqual(template.id, "medicine")
        XCTAssertEqual(template.keywords, ["藥", "服用"])
        XCTAssertEqual(template.version, 4)
        XCTAssertEqual(template.origin, .server)
        XCTAssertEqual(template.sampleJSON, #"{"drug":"普拿疼","dose":"500mg","times":3}"#)
    }

    @MainActor
    func testUploadPayloadMatchesAPIContract() throws {
        let record = ScanRecord(text: "合計 45", source: "camera", pageCount: 1, lineCount: 2, averageConfidence: 0.5, thumbnailData: nil)
        record.templateID = "receipt"
        record.jsonText = #"{"store":"全聯","total":45}"#
        record.classificationJSON = #"{"templateId":"receipt","confidence":0.9,"provider":"jev"}"#
        let id = UUID()
        let payload = ScanUploader.payload(for: record, id: id)
        guard case .object(let members) = payload else { return XCTFail("應為物件") }
        XCTAssertEqual(
            members.map(\.key),
            ["id", "createdAt", "source", "text", "templateId", "classification", "data", "lineCount", "averageConfidence", "pageCount", "device"]
        )
        XCTAssertEqual(payload["id"]?.stringValue, id.uuidString)
        XCTAssertEqual(payload["data"]?.compactString, #"{"store":"全聯","total":45}"#)
        XCTAssertEqual(record.title, "全聯")
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    func testSchemaBuilderAcceptsAllBuiltInSamples() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("需要 iOS 26") }
        for template in ScanTemplate.builtIns {
            XCTAssertNoThrow(try TemplateSchemaBuilder.generationSchema(for: template.sample), template.id)
        }
        let nested = try JSONValue.parse(#"{"a":{"b":{"c":[{"d":1}]}},"e":[],"f":null,"g":{}}"#)
        XCTAssertNoThrow(try TemplateSchemaBuilder.generationSchema(for: nested))
    }

    func testOnDeviceExtractionWhenAvailable() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("需要 iOS 26") }
        guard OnDeviceAIStatus.current.isAvailable else {
            throw XCTSkip("此環境無法使用 Apple Intelligence：\(OnDeviceAIStatus.current)")
        }
        // 虛擬機（例如 CI）可能回報可用但沒有模型資產；先用最小請求確認模型真的能執行
        do {
            let probe = LanguageModelSession(instructions: { "只回答 OK。" })
            _ = try await probe.respond(options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: nil)) {
                "OK?"
            }
        } catch {
            throw XCTSkip("模型回報可用但無法執行：\(error.localizedDescription)")
        }
        let template = ScanTemplate.builtIns[0]
        let text = "全聯福利中心\n2026/10/02 14:30\n鮮乳 1 45\n合計 45\n現金 100 找零 55"
        let data = try await FoundationModelsExtractor().extract(text: text, template: template)
        guard case .object(let members) = data, case .object(let sampleMembers) = template.sample else {
            return XCTFail("應為物件")
        }
        XCTAssertEqual(members.map(\.key), sampleMembers.map(\.key))
    }
    #endif
}
