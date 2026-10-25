import XCTest

@testable import Myra

/// Fixture-only AI evaluation. Nothing here reaches the network or a real model.
/// Catalogue and queries live in Tests/MyraTests/Fixtures/ai and are fictional.
private enum MyraAIEvalFixtures {
  struct Title: Decodable {
    var id: String
    var name: String
    var year: String
    var kind: String
    var genres: [String]
    var rating: Double
    var runtime: Int
    var language: String
    var state: String
    var watchlisted: Bool
    var overview: String
  }

  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/ai")

  static func catalogue() throws -> [Title] {
    let data = try Data(contentsOf: directory.appending(path: "catalogue.json"))
    return try JSONDecoder().decode([Title].self, from: data)
  }

  static func queries() throws -> [[String: Any]] {
    let data = try Data(contentsOf: directory.appending(path: "queries.json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  static func entertainmentTitle(_ fixture: Title) -> EntertainmentTitle {
    let root = URL(string: "https://fixture.invalid/library/")!
    let fileName = "\(fixture.id).mkv"
    let isSeries = fixture.kind == "series"
    let media = GlobalSearchResult(
      categoryID: UUID(), categoryName: "Fixture", categoryRoot: root,
      entry: DirectoryEntry(name: fileName, url: root.appending(path: fileName), kind: .file),
      relativePath: fileName, artworkURL: nil)
    let unfinished = fixture.state == "unfinished"
    let version = EntertainmentVersion(
      media: media, firstDiscovered: .now,
      progressSeconds: unfinished ? 600 : 0,
      duration: Double(fixture.runtime * 60),
      lastPlayed: unfinished ? .now : nil,
      season: isSeries ? 1 : nil, episode: isSeries ? 1 : nil)
    return EntertainmentTitle(
      id: fixture.id, name: fixture.name, year: fixture.year,
      kind: isSeries ? .series : .movie, versions: [version],
      metadata: EntertainmentMetadata(
        providerID: 1, title: fixture.name, overview: fixture.overview, posterURL: nil,
        rating: fixture.rating, voteCount: 100, releaseDate: "\(fixture.year)-01-01",
        genres: fixture.genres, language: fixture.language,
        runtimeMinutes: fixture.runtime > 0 ? fixture.runtime : nil))
  }

  static func personal(_ fixtures: [Title]) -> EntertainmentPersonalData {
    var data = EntertainmentPersonalData()
    for fixture in fixtures {
      if fixture.state == "watched" { data.watched.insert(fixture.id) }
      if fixture.watchlisted { data.watchlist.insert(fixture.id) }
    }
    return data
  }

  static func jsonString(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

/// A scripted stand-in for the on-device model. It answers from the candidates it can see:
/// when the expected title has a visible tN alias it uses it, otherwise it invents an ID.
private actor MyraScriptedModel: MyraAITransport {
  private let intentJSON: String
  private let expectedTitles: [(id: String, name: String)]
  private(set) var calls = 0
  private(set) var answerPromptBytes = 0
  private(set) var visibleExpected = 0
  private(set) var rawIDs = 0
  private(set) var groundedRawIDs = 0

  init(intentJSON: String, expectedTitles: [(id: String, name: String)]) {
    self.intentJSON = intentJSON
    self.expectedTitles = expectedTitles
  }

  func generate(
    provider: MyraAIProvider, model: String, key: String, instructions: String, prompt: String,
    maximumTokens: Int, language: String
  ) async throws -> String {
    calls += 1
    if instructions.contains("Extract catalogue") { return intentJSON }
    answerPromptBytes = max(answerPromptBytes, prompt.utf8.count)
    var recommendations: [[String: String]] = []
    for expected in expectedTitles.prefix(3) {
      if let alias = Self.alias(for: expected.name, in: prompt) {
        visibleExpected += 1
        rawIDs += 1
        groundedRawIDs += 1
        recommendations.append(["titleID": alias, "reason": "Matches the requested constraints."])
      } else if !expectedTitles.isEmpty {
        rawIDs += 1
        recommendations.append(["titleID": expected.id, "reason": "Matches the requested constraints."])
      }
    }
    let wire: [String: Any] = [
      "summary": "Grounded in the supplied catalogue facts.",
      "recommendations": recommendations, "actions": [], "tags": [],
    ]
    return MyraAIEvalFixtures.jsonString(wire)
  }

  func models(provider: MyraAIProvider, key: String) async throws -> [String] { ["scripted"] }

  /// Finds the alias nearest before the first catalogue occurrence of the title name.
  static func alias(for name: String, in prompt: String) -> String? {
    var searchStart = prompt.startIndex
    while let found = prompt.range(of: name, range: searchStart..<prompt.endIndex) {
      let windowStart =
        prompt.index(found.lowerBound, offsetBy: -min(200, prompt.distance(from: prompt.startIndex, to: found.lowerBound)))
      let window = String(prompt[windowStart..<found.lowerBound])
      if let regex = try? NSRegularExpression(pattern: "\\bt[0-9]{1,2}\\b"),
        let last = regex.matches(in: window, range: NSRange(window.startIndex..., in: window)).last,
        let range = Range(last.range, in: window)
      {
        return String(window[range])
      }
      searchStart = found.upperBound
    }
    return nil
  }
}

final class MyraAIReliabilityTests: XCTestCase {
  private struct QueryResult {
    var id: String
    var feature: String
    var calls: Int
    var answerBytes: Int
    var expected: Int
    var expectedVisible: Int
    var rawIDs: Int
    var groundedRawIDs: Int
    var succeeded: Bool
    var hit: Bool
    var message: String
  }

  /// Runs every fixture query through the public store with a scripted model.
  @MainActor
  private func runHostEvaluation() async throws -> [QueryResult] {
    let fixtures = try MyraAIEvalFixtures.catalogue()
    let titles = fixtures.map(MyraAIEvalFixtures.entertainmentTitle)
    let names = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0.name) })
    let personal = MyraAIEvalFixtures.personal(fixtures)
    var results: [QueryResult] = []
    for query in try MyraAIEvalFixtures.queries() {
      let id = query["id"] as? String ?? ""
      let feature = MyraAIFeature(rawValue: query["feature"] as? String ?? "") ?? .smartPick
      let expectedIDs = query["expected"] as? [String] ?? []
      let selected = query["selected"] as? [String] ?? []
      let modelIntent = MyraAIEvalFixtures.jsonString(query["modelIntent"] ?? [:])
      let model = MyraScriptedModel(
        intentJSON: modelIntent,
        expectedTitles: expectedIDs.map { ($0, names[$0] ?? $0) })
      let suite = "Myra-eval-\(id)-\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let ai = MyraAIStore(defaults: defaults, transport: model)
      ai.settings.dailyRequestLimit = 500
      await ai.execute(
        feature: feature, prompt: query["prompt"] as? String ?? "", titles: titles,
        personal: personal, revision: 1, selectedIDs: selected)
      let returned = ai.response?.recommendations.map(\.titleID) ?? []
      results.append(
        QueryResult(
          id: id, feature: feature.rawValue, calls: await model.calls,
          answerBytes: await model.answerPromptBytes, expected: expectedIDs.count,
          expectedVisible: await model.visibleExpected, rawIDs: await model.rawIDs,
          groundedRawIDs: await model.groundedRawIDs,
          succeeded: ai.errorMessage == nil && ai.response != nil,
          hit: !expectedIDs.isEmpty && expectedIDs.contains(where: returned.contains),
          message: ai.errorMessage ?? ""))
    }
    return results
  }

  @MainActor
  func testHostEvaluationHarnessRecordsBaselineMetrics() async throws {
    let results = try await runHostEvaluation()
    let label = ProcessInfo.processInfo.environment["MYRA_EVAL_LABEL"] ?? "current"
    print("MYRA-AI-HOST-EVAL \(label): id feature calls answerBytes expectedVisible/expected raw grounded success hit")
    for result in results {
      print(
        "MYRA-AI-HOST-EVAL \(result.id) \(result.feature) calls=\(result.calls) bytes=\(result.answerBytes) visible=\(result.expectedVisible)/\(result.expected) grounded=\(result.groundedRawIDs)/\(result.rawIDs) success=\(result.succeeded) hit=\(result.hit) \(result.message)"
      )
    }
    let labelled = results.filter { $0.expected > 0 }
    let hitRate = Double(labelled.filter(\.hit).count) / Double(max(1, labelled.count))
    let successRate = Double(results.filter(\.succeeded).count) / Double(max(1, results.count))
    let rawTotal = results.reduce(0) { $0 + $1.rawIDs }
    let groundedTotal = results.reduce(0) { $0 + $1.groundedRawIDs }
    let meanCalls = Double(results.reduce(0) { $0 + $1.calls }) / Double(max(1, results.count))
    let meanBytes = Double(results.reduce(0) { $0 + $1.answerBytes }) / Double(max(1, results.count))
    let maxBytes = results.map(\.answerBytes).max() ?? 0
    let twoCallShare = Double(results.filter { $0.calls >= 2 }.count) / Double(max(1, results.count))
    print(
      "MYRA-AI-HOST-EVAL SUMMARY \(label): queries=\(results.count) success=\(String(format: "%.2f", successRate)) hitRate=\(String(format: "%.2f", hitRate)) groundedRawIDRate=\(String(format: "%.2f", Double(groundedTotal) / Double(max(1, rawTotal)))) meanModelCalls=\(String(format: "%.2f", meanCalls)) twoCallShare=\(String(format: "%.2f", twoCallShare)) meanAnswerBytes=\(Int(meanBytes)) maxAnswerBytes=\(maxBytes)"
    )
    XCTAssertEqual(results.count, 25)
    // Intent, answer, and at most one reduced-context retry.
    XCTAssertTrue(results.allSatisfy { $0.calls <= 3 })
  }

  @MainActor
  func testStoreRejectsUngroundedOutputInsteadOfShowingUnknownTitles() async throws {
    let fixtures = try MyraAIEvalFixtures.catalogue()
    let titles = fixtures.map(MyraAIEvalFixtures.entertainmentTitle)
    let suite = "Myra-grounding-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = MyraScriptedModel(intentJSON: "{}", expectedTitles: [("invented-title", "Invented Title")])
    let ai = MyraAIStore(defaults: defaults, transport: model)
    await ai.execute(
      feature: .summary, prompt: "Summarise", titles: titles, personal: .init(), revision: 1,
      selectedIDs: ["glass-harbor"])
    XCTAssertNil(ai.response?.recommendations.first { $0.titleID == "invented-title" })
  }

  /// Opt-in: MYRA_ONDEVICE_EVAL=1 runs every fixture query through the real Apple provider.
  @MainActor
  func testOnDeviceLatencyForAppleProvider() async throws {
    guard ProcessInfo.processInfo.environment["MYRA_ONDEVICE_EVAL"] == "1" else {
      throw XCTSkip("Set MYRA_ONDEVICE_EVAL=1 to run on-device latency measurement")
    }
    if let reason = MyraAIProviderClient.appleAvailability() { throw XCTSkip(reason) }
    let fixtures = try MyraAIEvalFixtures.catalogue()
    let titles = fixtures.map(MyraAIEvalFixtures.entertainmentTitle)
    let personal = MyraAIEvalFixtures.personal(fixtures)
    let label = ProcessInfo.processInfo.environment["MYRA_EVAL_LABEL"] ?? "current"
    var latencies: [Double] = []
    var successes = 0
    for query in try MyraAIEvalFixtures.queries() {
      let id = query["id"] as? String ?? ""
      let feature = MyraAIFeature(rawValue: query["feature"] as? String ?? "") ?? .smartPick
      let suite = "Myra-device-\(id)-\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let ai = MyraAIStore(defaults: defaults, transport: MyraAIProviderClient())
      ai.settings.dailyRequestLimit = 500
      let start = ContinuousClock.now
      await ai.execute(
        feature: feature, prompt: query["prompt"] as? String ?? "", titles: titles,
        personal: personal, revision: 1, selectedIDs: query["selected"] as? [String] ?? [])
      let seconds = Double((start.duration(to: .now)).components.seconds)
        + Double(start.duration(to: .now).components.attoseconds) / 1e18
      latencies.append(seconds)
      if ai.errorMessage == nil, ai.response != nil { successes += 1 }
      print("MYRA-AI-DEVICE-EVAL \(label) \(id) \(feature.rawValue) seconds=\(String(format: "%.2f", seconds)) success=\(ai.errorMessage == nil) \(ai.errorMessage ?? "")")
    }
    let sorted = latencies.sorted()
    func percentile(_ p: Double) -> Double {
      let rank = Int((Double(sorted.count) * p).rounded(.up))
      return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
    print("MYRA-AI-DEVICE-EVAL SUMMARY \(label): n=\(latencies.count) success=\(successes) p50=\(String(format: "%.2f", percentile(0.5)))s p95=\(String(format: "%.2f", percentile(0.95)))s")
    XCTAssertEqual(latencies.count, 25)
  }

  // MARK: - Local intent parser

  func testLocalParserMatchesLabelledQueries() throws {
    var checked = 0
    for query in try MyraAIEvalFixtures.queries() {
      guard let expected = query["expectConfident"] as? Bool,
        let feature = MyraAIFeature(rawValue: query["feature"] as? String ?? ""),
        feature.usesLocalIntent
      else { continue }
      let parse = MyraIntentParser.parse(
        prompt: query["prompt"] as? String ?? "", feature: feature,
        catalogueGenres: [
          "Thriller", "Science Fiction", "Documentary", "Animation", "Family", "Comedy", "Mystery",
          "Romance", "Crime", "Drama", "Action", "Horror", "Fantasy", "Music",
        ],
        catalogueTitleWords: ["glass", "harbor", "iron", "meridian", "quiet", "orbit", "winter", "cafe", "garden"])
      let id = query["id"] as? String ?? ""
      XCTAssertEqual(parse.isConfident, expected, "confidence for \(id)")
      checked += 1
      if expected, let want = query["expectIntent"] as? [String: Any] {
        let got =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(parse.intent)) as? [String: Any]
          ?? [:]
        for (key, value) in want {
          XCTAssertEqual(got[key].map { "\($0)" }, "\(value)", "intent field \(key) for \(id)")
        }
      }
    }
    XCTAssertGreaterThanOrEqual(checked, 20)
  }

  func testLocalParserReadsTimeWordsAndNegation() {
    let limit = MyraIntentParser.parse(prompt: "unwatched movies under two hours", feature: .smartPick)
    XCTAssertEqual(limit.intent.maximumMinutes, 120)
    XCTAssertTrue(limit.isConfident)
    let negated = MyraIntentParser.parse(prompt: "no horror please", feature: .smartPick)
    XCTAssertFalse(negated.isConfident)
    let vague = MyraIntentParser.parse(prompt: "something cosy", feature: .smartPick)
    XCTAssertTrue(vague.isConfident)
    XCTAssertNil(vague.intent.genre)
  }

  // MARK: - Typed output, schemas, and validation

  func testEveryFeatureHasOneTypedOutputFormat() {
    XCTAssertEqual(MyraAIFeature.smartPick.outputFormat, .picks)
    XCTAssertEqual(MyraAIFeature.summary.outputFormat, .narrative)
    XCTAssertEqual(MyraAIFeature.assistant.outputFormat, .actions)
    XCTAssertEqual(MyraAIFeature.allCases.count, 16)
  }

  func testTypedSchemasBuildAndRejectEmptyAliasSets() throws {
    guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
    let aliases = (1...8).map { "t\($0)" }
    _ = try MyraAppleModelRuntime.schema(for: .picks, aliases: aliases)
    _ = try MyraAppleModelRuntime.schema(for: .actions, aliases: aliases)
    XCTAssertThrowsError(try MyraAppleModelRuntime.schema(for: .picks, aliases: []))
  }

  @MainActor func testRecommendationListIsCappedAtThree() throws {
    let titles = try MyraAIEvalFixtures.catalogue().map(MyraAIEvalFixtures.entertainmentTitle)
    var aliases: [String: EntertainmentTitle] = [:]
    for (offset, title) in titles.prefix(5).enumerated() { aliases["t\(offset + 1)"] = title }
    let wire = MyraAIWireResponse(
      summary: "Five picks",
      recommendations: (1...5).map { MyraAIRecommendation(titleID: "t\($0)", reason: "Fact") },
      actions: [], tags: [])
    let result = try MyraAIStore.validate(
      wire, aliases: aliases, feature: .smartPick, maximumMinutes: nil, provider: "test")
    XCTAssertEqual(result.recommendations.count, 3)
  }

  // MARK: - Compact context

  func testOnDeviceContextIsCompactAndWithinBudget() throws {
    let fixtures = try MyraAIEvalFixtures.catalogue()
    let titles = fixtures.map(MyraAIEvalFixtures.entertainmentTitle)
    let personal = MyraAIEvalFixtures.personal(fixtures)
    let picks = try MyraAIContext.prepare(
      titles: titles, personal: personal, config: .init(), feature: .smartPick,
      prompt: "a sci-fi movie", selectedIDs: [], intent: nil, subtitleText: nil)
    XCTAssertLessThanOrEqual(picks.prompt.utf8.count, MyraAIContext.onDeviceByteBudget)
    XCTAssertLessThanOrEqual(picks.aliases.count, 8)
    XCTAssertFalse(picks.prompt.contains("SYNOPSES"))
    let lines = picks.prompt.split(separator: "\n").filter { $0.hasPrefix("t") }
    XCTAssertEqual(lines.count, picks.aliases.count)
    XCTAssertTrue(lines.allSatisfy { $0.contains(" | ") })
    let summary = try MyraAIContext.prepare(
      titles: titles, personal: personal, config: .init(), feature: .summary, prompt: "summary",
      selectedIDs: ["glass-harbor"], intent: nil, subtitleText: nil)
    XCTAssertTrue(summary.prompt.contains("SYNOPSES"))
  }

  // MARK: - Recovery, timeout, fallback, prewarm, streaming

  @MainActor private func makeStore(_ model: any MyraAITransport) throws -> MyraAIStore {
    let suite = "Myra-reliability-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let ai = MyraAIStore(defaults: defaults, transport: model)
    ai.settings.dailyRequestLimit = 500
    return ai
  }

  private func fixtureTitles() throws -> ([EntertainmentTitle], EntertainmentPersonalData) {
    let fixtures = try MyraAIEvalFixtures.catalogue()
    return (fixtures.map(MyraAIEvalFixtures.entertainmentTitle), MyraAIEvalFixtures.personal(fixtures))
  }

  @MainActor func testRetriesOnceWithLessContextAfterDecodingFailure() async throws {
    let (titles, personal) = try fixtureTitles()
    let model = MyraSequenceModel(failures: [MyraAIError.decodingFailure])
    let ai = try makeStore(model)
    await ai.execute(
      feature: .smartPick, prompt: "unwatched movies", titles: titles, personal: personal, revision: 1)
    XCTAssertNil(ai.errorMessage)
    XCTAssertEqual(ai.response?.path, .model)
    let prompts = await model.answerPrompts
    XCTAssertEqual(prompts.count, 2)
    XCTAssertLessThan(prompts[1].utf8.count, prompts[0].utf8.count)
  }

  @MainActor func testOverBudgetOnDeviceAnswerFallsBackForRecommendations() async throws {
    let (titles, personal) = try fixtureTitles()
    let ai = try makeStore(MyraSequenceModel(delay: .seconds(3)))
    ai.onDeviceTimeout = .milliseconds(150)
    await ai.execute(
      feature: .plan, prompt: "Plan tonight with 120 minutes", titles: titles, personal: personal,
      revision: 1)
    XCTAssertNil(ai.errorMessage)
    XCTAssertEqual(ai.response?.path, .deterministicFallback)
    XCTAssertTrue(ai.response?.pathReason?.contains("did not finish") ?? false)
    let total =
      ai.response?.recommendations.compactMap { rec in
        titles.first { $0.id == rec.titleID }.flatMap { MyraAIContext.runtime($0) }
      }.reduce(0, +) ?? 0
    XCTAssertLessThanOrEqual(total, 120)
    XCTAssertFalse(ai.response?.recommendations.isEmpty ?? true)
  }

  @MainActor func testNonRecommendationTimeoutShowsErrorInsteadOfFallback() async throws {
    let (titles, personal) = try fixtureTitles()
    let ai = try makeStore(MyraSequenceModel(delay: .seconds(3)))
    ai.onDeviceTimeout = .milliseconds(150)
    await ai.execute(
      feature: .summary, prompt: "summary", titles: titles, personal: personal, revision: 1,
      selectedIDs: ["glass-harbor"])
    XCTAssertNil(ai.response)
    XCTAssertTrue(ai.errorMessage?.contains("did not finish") ?? false)
  }

  @MainActor func testUnavailableAssetsFallBackWithSpecificReason() async throws {
    let (titles, personal) = try fixtureTitles()
    let model = MyraSequenceModel(failures: Array(repeating: MyraAIError.assetsUnavailable, count: 3))
    let ai = try makeStore(model)
    await ai.execute(
      feature: .smartPick, prompt: "Pick something uplifting", titles: titles, personal: personal,
      revision: 1)
    XCTAssertEqual(ai.response?.path, .deterministicFallback)
    XCTAssertTrue(ai.response?.pathReason?.contains("downloading") ?? false)
    XCTAssertFalse(ai.response?.recommendations.isEmpty ?? true)
  }

  @MainActor func testFallbackIsNotCachedSoTheModelIsAskedAgain() async throws {
    let (titles, personal) = try fixtureTitles()
    let model = MyraSequenceModel(failures: [MyraAIError.assetsUnavailable])
    let ai = try makeStore(model)
    await ai.execute(
      feature: .smartPick, prompt: "Pick something uplifting", titles: titles, personal: personal,
      revision: 1)
    XCTAssertEqual(ai.response?.path, .deterministicFallback)
    await ai.execute(
      feature: .smartPick, prompt: "Pick something uplifting", titles: titles, personal: personal,
      revision: 1)
    XCTAssertEqual(ai.response?.path, .model, "fallback results are not cached")
  }

  @MainActor func testPrewarmRunsOnlyForOnDeviceProvider() async throws {
    let model = MyraSequenceModel()
    let ai = try makeStore(model)
    ai.prewarm(feature: .smartPick)
    try await Task.sleep(for: .milliseconds(100))
    let first = await model.prewarmed
    XCTAssertEqual(first, [.smartPick])
    ai.settings.provider = .claude
    ai.prewarm(feature: .summary)
    try await Task.sleep(for: .milliseconds(100))
    let second = await model.prewarmed
    XCTAssertEqual(second, [.smartPick])
  }

  @MainActor func testNarrativeRequestReceivesStreamingHandler() async throws {
    let (titles, personal) = try fixtureTitles()
    let model = MyraSequenceModel(partials: ["Glass", "Glass Harbor is"])
    let ai = try makeStore(model)
    await ai.execute(
      feature: .summary, prompt: "summary", titles: titles, personal: personal, revision: 1,
      selectedIDs: ["glass-harbor"])
    let sawHandler = await model.sawStreamingHandler
    XCTAssertTrue(sawHandler)
    XCTAssertEqual(ai.partialSummary, "")
  }

  @MainActor func testConfidentRequestNeedsOnlyOneModelCall() async throws {
    let (titles, personal) = try fixtureTitles()
    let model = MyraSequenceModel()
    let ai = try makeStore(model)
    await ai.execute(
      feature: .smartPick, prompt: "unwatched Korean thrillers after 2018", titles: titles,
      personal: personal, revision: 1)
    let intents = await model.intentCalls
    let answers = await model.answerPrompts.count
    XCTAssertEqual(intents, 0)
    XCTAssertEqual(answers, 1)
  }

  func testErrorMessagesAreSpecificForEachOnDeviceFailure() {
    let errors: [MyraAIError] = [
      .contextOverflow, .decodingFailure, .guardrail, .refusal, .assetsUnavailable, .busy,
      .unsupportedSchema, .timedOut,
    ]
    let texts = errors.map { $0.errorDescription ?? "" }
    XCTAssertTrue(texts.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(Set(texts).count, errors.count)
    XCTAssertTrue(MyraAIError.contextOverflow.isRetryableWithLessContext)
    XCTAssertFalse(MyraAIError.guardrail.isRetryableWithLessContext)
  }
}

/// Scripted model for the Apple pipeline: records prompts, delays, and fails in order.
private actor MyraSequenceModel: MyraAITransport {
  private var failures: [Error]
  private let delay: Duration?
  private let partials: [String]
  private(set) var answerPrompts: [String] = []
  private(set) var intentCalls = 0
  private(set) var prewarmed: [MyraAIFeature] = []
  private(set) var sawStreamingHandler = false

  init(failures: [Error] = [], delay: Duration? = nil, partials: [String] = []) {
    self.failures = failures
    self.delay = delay
    self.partials = partials
  }

  func generate(_ request: MyraAIRequest) async throws -> String {
    if case .intent = request.purpose {
      intentCalls += 1
      return "{}"
    }
    answerPrompts.append(request.prompt)
    if request.onPartialSummary != nil { sawStreamingHandler = true }
    if let delay { try await Task.sleep(for: delay) }
    for text in partials { request.onPartialSummary?(text) }
    if !failures.isEmpty { throw failures.removeFirst() }
    return
      "{\"summary\":\"Grounded\",\"recommendations\":[{\"titleID\":\"t1\",\"reason\":\"Indexed fact\"}],\"actions\":[],\"tags\":[]}"
  }

  func generate(
    provider: MyraAIProvider, model: String, key: String, instructions: String, prompt: String,
    maximumTokens: Int, language: String
  ) async throws -> String {
    try await generate(
      MyraAIRequest(
        provider: provider, model: model, key: key, instructions: instructions, prompt: prompt,
        maximumTokens: maximumTokens, language: language, purpose: .answer(.summary, .narrative)))
  }

  func models(provider: MyraAIProvider, key: String) async throws -> [String] { ["scripted"] }

  func prewarm(feature: MyraAIFeature) async { prewarmed.append(feature) }
}
