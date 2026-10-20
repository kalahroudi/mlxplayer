import XCTest
@testable import MLXPlayerCore

final class AdvisorTests: XCTestCase {
    let GB: UInt64 = 1_073_741_824

    func mac(_ gb: UInt64, bandwidth: Double = 400) -> HardwareProfile {
        HardwareProfile(chip: "Apple M3 Max", memoryBytes: gb * GB, gpuCores: 40, cpuCores: 16,
                        performanceCores: 12, bandwidthGBs: bandwidth)
    }

    func testNameParsing() {
        let a = NameParser.parse("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit")
        XCTAssertEqual(a.totalB, 30)
        XCTAssertEqual(a.activeB, 3)
        XCTAssertEqual(a.bits, 4)
        let b = NameParser.parse("mlx-community/Llama-3.2-1B-Instruct-8bit")
        XCTAssertEqual(b.totalB, 1)
        XCTAssertNil(b.activeB)
        XCTAssertEqual(b.bits, 8)
        let c = NameParser.parse("mlx-community/Qwen3-0.6B-bf16")
        XCTAssertEqual(c.totalB, 0.6)
        XCTAssertEqual(c.bits, 16)
        XCTAssertEqual(NameParser.parse("mlx-community/gemma-3-4b-it-qat-4bit").totalB, 4)
        XCTAssertEqual(NameParser.parse("x/y-gpt-oss-20b-MXFP4-Q8").bits, 4)
    }

    func testVariantDetection() {
        XCTAssertEqual(NameParser.variant(id: "x/Qwen3-8B-abliterated-4bit", tags: []), .abliterated)
        XCTAssertEqual(NameParser.variant(id: "x/Llama-3-8B-Uncensored-4bit", tags: []), .uncensored)
        XCTAssertEqual(NameParser.variant(id: "mlx-community/Qwen3-8B-4bit", tags: []), .standard)
    }

    func testConfigParsingUsesTextConfigAndDerivesHeadDim() {
        let json = #"{"text_config":{"num_hidden_layers":48,"num_attention_heads":32,"num_key_value_heads":4,"hidden_size":2048,"max_position_embeddings":262144}}"#
        let cfg = ModelConfig.parse(Data(json.utf8))
        XCTAssertEqual(cfg?.layers, 48)
        XCTAssertEqual(cfg?.kvHeads, 4)
        XCTAssertEqual(cfg?.headDim, 64)
        XCTAssertEqual(cfg?.maxPositionEmbeddings, 262_144)
    }

    func testKVBytesPerToken() {
        var m = ModelMetadata.fromName("mlx-community/Qwen3-30B-A3B-Instruct-4bit")
        m = m.applying(config: ModelConfig(layers: 48, kvHeads: 4, headDim: 128, maxPositionEmbeddings: 262_144))
        XCTAssertEqual(m.kvBytesPerToken(), Double(2 * 48 * 4 * 128 * 2))
        XCTAssertTrue(m.hasExactKV)
    }

    func testBudgetNeverStarvesMacOS() {
        let adv = Advisor(hardware: mac(64))
        XCTAssertEqual(adv.budgetBytes, 48 * GB)   // 75% GPU limit
        var hw = mac(64)
        hw.gpuLimitBytes = 63 * GB
        XCTAssertEqual(Advisor(hardware: hw).budgetBytes, 56 * GB) // 64 - 8 reserve
    }

    func testBigModelDoesNotFitSmallMac() {
        let adv = Advisor(hardware: mac(16))
        let m = ModelMetadata.fromName("mlx-community/Qwen3-235B-A22B-4bit")
        XCTAssertEqual(adv.assess(m, task: .coding).verdict, .wontFit)
    }

    func testMoEIsFasterThanDenseOfSameSize() {
        let adv = Advisor(hardware: mac(64))
        let moe = ModelMetadata.fromName("mlx-community/Qwen3-30B-A3B-4bit")
        let dense = ModelMetadata.fromName("mlx-community/Qwen3-32B-4bit")
        XCTAssertGreaterThan(adv.tokensPerSecond(moe), adv.tokensPerSecond(dense) * 3)
    }

    func testRecommendedContextShrinksWhenMemoryIsTight() {
        var big = ModelMetadata.fromName("mlx-community/Qwen2.5-Coder-32B-Instruct-8bit")
        big = big.applying(config: ModelConfig(layers: 64, kvHeads: 8, headDim: 128, maxPositionEmbeddings: 32_768))
        let roomy = Advisor(hardware: mac(128)).assess(big, task: .coding)
        let cramped = Advisor(hardware: mac(48)).assess(big, task: .coding)
        XCTAssertLessThanOrEqual(cramped.recommendedContext, roomy.recommendedContext)
        XCTAssertNotEqual(cramped.verdict, .comfortable)
        XCTAssertEqual(roomy.verdict, .comfortable)
    }

    func testRecommendationsAreDistinctAndOrdered() {
        let adv = Advisor(hardware: mac(64))
        let names = [
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-32B-Instruct-8bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Qwen3-235B-A22B-4bit",
        ]
        let models = names.map { ModelMetadata.fromName($0) }
        let rec = adv.recommend(from: models, task: .coding)
        XCTAssertNotNil(rec.bestOverall)
        XCTAssertEqual(rec.fastest?.model.id, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        let ids = [rec.bestOverall, rec.highestQuality, rec.fastest].compactMap { $0?.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains("mlx-community/Qwen3-235B-A22B-4bit"))
    }

    func testTaskInference() {
        XCTAssertEqual(AdvisorTask.infer(from: "Refactor a large TypeScript monorepo"), .coding)
        XCTAssertEqual(AdvisorTask.infer(from: "summarize long PDF contracts"), .longDocuments)
        XCTAssertEqual(AdvisorTask.infer(from: "hello"), .chat)
    }

    func testFilter() {
        var f = ModelFilter()
        f.bits = [4]
        f.families = [.qwen]
        let models = ["mlx-community/Qwen3-8B-4bit", "mlx-community/Qwen3-8B-8bit", "mlx-community/Llama-3.2-1B-4bit",
                      "x/Qwen3-8B-abliterated-4bit"].map { ModelMetadata.fromName($0) }
        XCTAssertEqual(f.apply(models, advisor: nil).map(\.id), ["mlx-community/Qwen3-8B-4bit"])
        f.variant = .abliterated
        XCTAssertEqual(f.apply(models, advisor: nil).map(\.id), ["x/Qwen3-8B-abliterated-4bit"])
    }

    func testChipBandwidth() {
        XCTAssertEqual(ChipTable.bandwidth(chip: "Apple M3 Max", gpuCores: 40).gbs, 400)
        XCTAssertEqual(ChipTable.bandwidth(chip: "Apple M3 Max", gpuCores: 30).gbs, 300)
        XCTAssertTrue(ChipTable.bandwidth(chip: "Apple M9 Plus", gpuCores: 10).estimate)
    }

    func testDefaultGPULimit() {
        XCTAssertEqual(HardwareProfile.defaultGPULimit(memoryBytes: 64 * GB), 48 * GB)
        XCTAssertEqual(Double(HardwareProfile.defaultGPULimit(memoryBytes: 16 * GB)) / Double(16 * GB), 2.0 / 3.0, accuracy: 0.001)
    }
}
