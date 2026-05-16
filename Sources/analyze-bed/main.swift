import Foundation
import AVFoundation
import SoundAnalysis

// MARK: - R2 config (mirrored from spatial-field-converter/Sources/Mac/R2Uploader.swift)

private let r2AccountId = "6a378e6919e5a3f1cbd84db6c1ad5443"
private let r2AccessKey = "97545dddf4f1f07559999dceed884792"
private let r2SecretKey = "3d7187bcc70bcbe9fbd0b0ea773eb751dd13d18cb2beb8c7256835310c968de0"
private let r2Bucket    = "cloud-to-float-on"
private let r2Region    = "auto"
private var r2Endpoint: String { "https://\(r2AccountId).r2.cloudflarestorage.com" }

private let awsPath = "/opt/homebrew/bin/aws"

private let confoundsNote = "rail_transport and elk_bugle are known YAMNet confounds for tropical forest insect/frog/bird patterns. Remap in downstream consumers."

// MARK: - Data models

struct ClassificationEvent: Codable {
    let startSec: Double
    let endSec: Double
    let label: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec   = "end_sec"
        case label
        case confidence
    }
}

struct AnalysisResult: Codable {
    let source: String
    let durationSec: Double
    let analyzerVersion: String
    let analyzedAt: String
    let events: [ClassificationEvent]
    let summary: Summary
    let confoundsNote: String

    enum CodingKeys: String, CodingKey {
        case source
        case durationSec    = "duration_sec"
        case analyzerVersion = "analyzer_version"
        case analyzedAt     = "analyzed_at"
        case events
        case summary
        case confoundsNote  = "confounds_note"
    }

    struct Summary: Codable {
        let topCategories: [Category]
        let uniqueLabels: Int
        let medianEventDurationSec: Double

        enum CodingKeys: String, CodingKey {
            case topCategories       = "top_categories"
            case uniqueLabels        = "unique_labels"
            case medianEventDurationSec = "median_event_duration_sec"
        }

        struct Category: Codable {
            let label: String
            let totalSeconds: Double
            let eventCount: Int

            enum CodingKeys: String, CodingKey {
                case label
                case totalSeconds = "total_seconds"
                case eventCount   = "event_count"
            }
        }
    }
}

// MARK: - Classification observer (collects raw SoundAnalysis windows)

final class ClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var rawResults: [(timeSec: Double, label: String, confidence: Double)] = []
    var confidenceThreshold: Double = 0.3

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let cr = result as? SNClassificationResult else { return }
        guard let top = cr.classifications.first, top.confidence >= confidenceThreshold else { return }
        let t = cr.timeRange.start.seconds
        lock.lock(); defer { lock.unlock() }
        rawResults.append((t, top.identifier, top.confidence))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        fputs("  [SoundAnalysis error] \(error.localizedDescription)\n", stderr)
    }

    /// Group contiguous (within 1.5 s gap) same-label entries into merged events.
    func clusterEvents() -> [ClassificationEvent] {
        let sorted = rawResults.sorted { $0.timeSec < $1.timeSec }
        var events: [ClassificationEvent] = []
        guard !sorted.isEmpty else { return events }

        let windowSec = 0.975
        let maxGap    = 1.5

        var clusterLabel  = sorted[0].label
        var clusterStart  = sorted[0].timeSec
        var clusterEnd    = sorted[0].timeSec + windowSec
        var confidences   = [sorted[0].confidence]

        for r in sorted.dropFirst() {
            let rEnd = r.timeSec + windowSec
            if r.label == clusterLabel && r.timeSec - clusterEnd <= maxGap {
                // Extend current cluster
                clusterEnd = max(clusterEnd, rEnd)
                confidences.append(r.confidence)
            } else {
                // Commit current cluster
                let meanConf = confidences.reduce(0, +) / Double(confidences.count)
                events.append(ClassificationEvent(startSec: clusterStart,
                                                  endSec: clusterEnd,
                                                  label: clusterLabel,
                                                  confidence: (meanConf * 1000).rounded() / 1000))
                // Start new cluster
                clusterLabel = r.label
                clusterStart = r.timeSec
                clusterEnd   = rEnd
                confidences  = [r.confidence]
            }
        }
        // Commit last cluster
        let meanConf = confidences.reduce(0, +) / Double(confidences.count)
        events.append(ClassificationEvent(startSec: clusterStart,
                                          endSec: clusterEnd,
                                          label: clusterLabel,
                                          confidence: (meanConf * 1000).rounded() / 1000))
        return events
    }
}

// MARK: - Median helper

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let mid = s.count / 2
    return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
}

// MARK: - Build summary

func buildSummary(from events: [ClassificationEvent]) -> AnalysisResult.Summary {
    var byLabel: [String: (totalSec: Double, count: Int)] = [:]
    for e in events {
        let dur = e.endSec - e.startSec
        byLabel[e.label, default: (0, 0)].totalSec += dur
        byLabel[e.label, default: (0, 0)].count     += 1
    }
    let sorted = byLabel.sorted { $0.value.totalSec > $1.value.totalSec }
    let top = sorted.prefix(20).map {
        AnalysisResult.Summary.Category(
            label: $0.key,
            totalSeconds: ($0.value.totalSec * 10).rounded() / 10,
            eventCount: $0.value.count
        )
    }
    let durations = events.map { $0.endSec - $0.startSec }
    return AnalysisResult.Summary(
        topCategories: top,
        uniqueLabels: byLabel.count,
        medianEventDurationSec: (median(durations) * 100).rounded() / 100
    )
}

// MARK: - ISO8601 timestamp

func iso8601Now() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: Date())
}

// MARK: - ffmpeg decode to 16kHz mono WAV

func decodeTo16kMono(inputURL: URL) throws -> URL {
    let ffmpeg = findFFmpeg()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString + ".wav")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-y", "-i", inputURL.path,
                   "-ar", "16000", "-ac", "1", "-f", "wav", tmp.path]
    let errPipe = Pipe()
    p.standardOutput = Pipe()  // discard stdout
    p.standardError  = errPipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw NSError(domain: "ffmpeg", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return tmp
}

func findFFmpeg() -> String {
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "ffmpeg"
}

// MARK: - Core analyzer

func analyzeFile(url: URL, source: String, confidenceThreshold: Double) async throws -> AnalysisResult {
    print("  Decoding to 16 kHz mono WAV via ffmpeg …")
    let wavURL = try decodeTo16kMono(inputURL: url)
    defer { try? FileManager.default.removeItem(at: wavURL) }

    // Read WAV into AVAudioPCMBuffer
    let audioFile = try AVAudioFile(forReading: wavURL)
    let format    = audioFile.processingFormat  // should be Float32, 16kHz, 1ch
    let frameCount = AVAudioFrameCount(audioFile.length)

    print("  Audio: \(format.sampleRate) Hz, \(format.channelCount) ch, \(frameCount) frames")

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "analyzer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot allocate PCM buffer"])
    }
    try audioFile.read(into: pcmBuffer)
    pcmBuffer.frameLength = frameCount

    let durationSec = Double(frameCount) / format.sampleRate

    // Set up SoundAnalysis stream analyzer
    let streamAnalyzer = SNAudioStreamAnalyzer(format: format)
    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
    request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: CMTimeScale(format.sampleRate))
    request.overlapFactor = 0.5

    let observer = ClassificationObserver()
    observer.confidenceThreshold = confidenceThreshold
    try streamAnalyzer.add(request, withObserver: observer)

    // Process in chunks to show progress
    let chunkFrames: AVAudioFrameCount = 16000 * 10  // 10-second chunks
    var frameOffset: AVAudioFramePosition = 0
    var chunksProcessed = 0
    let totalChunks = Int((Double(frameCount) / Double(chunkFrames)).rounded(.up))

    print("  Analyzing \(totalChunks) chunks (10 s each) …")

    while frameOffset < AVAudioFramePosition(frameCount) {
        let remaining = AVAudioFrameCount(AVAudioFramePosition(frameCount) - frameOffset)
        let thisChunk = min(chunkFrames, remaining)

        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisChunk) else { break }
        chunk.frameLength = thisChunk

        // Copy frames manually
        if let srcPtr = pcmBuffer.floatChannelData?[0],
           let dstPtr = chunk.floatChannelData?[0] {
            dstPtr.initialize(from: srcPtr.advanced(by: Int(frameOffset)), count: Int(thisChunk))
        }

        try streamAnalyzer.analyze(chunk, atAudioFramePosition: frameOffset)
        frameOffset += AVAudioFramePosition(thisChunk)
        chunksProcessed += 1

        if chunksProcessed % 6 == 0 || chunksProcessed == totalChunks {
            let pct = Int(Double(chunksProcessed) / Double(totalChunks) * 100)
            print("  … \(pct)% (\(Int(Double(frameOffset) / format.sampleRate))s / \(Int(durationSec))s)")
        }
    }

    streamAnalyzer.completeAnalysis()

    let rawCount = observer.rawResults.count
    print("  Raw classification windows: \(rawCount)")

    // If nothing came back above threshold, retry with lower threshold
    var events: [ClassificationEvent]
    if rawCount == 0 && confidenceThreshold > 0.1 {
        print("  No results above \(confidenceThreshold) — retrying with threshold 0.1")
        observer.confidenceThreshold = 0.1
        // Re-run (simple: re-create analyzer from same buffer)
        let streamAnalyzer2 = SNAudioStreamAnalyzer(format: format)
        let request2 = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request2.windowDuration = CMTime(seconds: 0.975, preferredTimescale: CMTimeScale(format.sampleRate))
        request2.overlapFactor  = 0.5
        let observer2 = ClassificationObserver()
        observer2.confidenceThreshold = 0.1
        try streamAnalyzer2.add(request2, withObserver: observer2)
        // replay in one shot (buffer is already in memory)
        try streamAnalyzer2.analyze(pcmBuffer, atAudioFramePosition: 0)
        streamAnalyzer2.completeAnalysis()
        print("  Raw windows at 0.1 threshold: \(observer2.rawResults.count)")
        events = observer2.clusterEvents()
    } else {
        events = observer.clusterEvents()
    }

    print("  Clustered events: \(events.count)")

    let summary = buildSummary(from: events)
    return AnalysisResult(
        source: source,
        durationSec: (durationSec * 10).rounded() / 10,
        analyzerVersion: "apple-soundanalysis-v1",
        analyzedAt: iso8601Now(),
        events: events,
        summary: summary,
        confoundsNote: confoundsNote
    )
}

// MARK: - R2 helpers

func awsEnv() -> [String: String] {
    [
        "AWS_ACCESS_KEY_ID": r2AccessKey,
        "AWS_SECRET_ACCESS_KEY": r2SecretKey,
        "AWS_DEFAULT_REGION": r2Region,
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    ]
}

func downloadFromR2(r2Key: String, to localURL: URL) throws {
    let src = "s3://\(r2Bucket)/\(r2Key)"
    print("  Downloading \(src) …")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3", "cp", src, localURL.path,
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region, "--no-progress"]
    p.environment = awsEnv()
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError  = errPipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw NSError(domain: "aws", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "aws s3 cp failed: \(msg)"])
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
    print("  Downloaded \(localURL.lastPathComponent) (\(size / 1_048_576) MB)")
}

func uploadToR2(localURL: URL, r2Key: String) throws {
    let dst = "s3://\(r2Bucket)/\(r2Key)"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3", "cp", localURL.path, dst,
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region, "--no-progress",
                   "--content-type", "application/json"]
    p.environment = awsEnv()
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError  = errPipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw NSError(domain: "aws", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "aws s3 cp upload failed: \(msg)"])
    }
}

/// Returns true if the given R2 key exists (head-object check).
func r2KeyExists(_ key: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3api", "head-object",
                   "--bucket", r2Bucket,
                   "--key", key,
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region]
    p.environment = awsEnv()
    p.standardOutput = Pipe()
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// List all bed.m4a keys under stems/spatial-mix/field-recording/
func listAllFieldRecordingBeds() throws -> [(key: String, slug: String, prefix: String)] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3", "ls", "s3://\(r2Bucket)/stems/spatial-mix/field-recording/",
                   "--recursive",
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region]
    p.environment = awsEnv()
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError  = Pipe()
    try p.run()
    p.waitUntilExit()
    let output = (try? outPipe.fileHandleForReading.readToEnd())
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""

    var results: [(key: String, slug: String, prefix: String)] = []
    for line in output.components(separatedBy: "\n") {
        // Format: "2026-05-15 18:31:07   84322633 stems/spatial-mix/..."
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { continue }
        let key = String(parts[3])
        guard key.hasSuffix("/bed.m4a") else { continue }
        // prefix = everything up to and including the trailing slash before bed.m4a
        let prefix = String(key.dropLast("bed.m4a".count))
        // Slug = last non-empty directory component
        let slug = key.components(separatedBy: "/").dropLast().last ?? key
        results.append((key, slug, prefix))
    }
    return results
}

// MARK: - JSON write helper

func writeJSON(_ result: AnalysisResult, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    try data.write(to: url)
}

// MARK: - Catalog update

struct CatalogAnalysisFields {
    let slug: String
    let analyzedAt: String
    let analyzerVersion: String
    let dominantCategories: [String]
    let uniqueLabelCount: Int
}

func downloadCatalog(to localURL: URL) throws {
    let src = "s3://\(r2Bucket)/catalog.json"
    print("  Downloading catalog.json …")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3", "cp", src, localURL.path,
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region, "--no-progress"]
    p.environment = awsEnv()
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError  = errPipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw NSError(domain: "aws", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "catalog download failed: \(msg)"])
    }
}

func uploadCatalog(from localURL: URL) throws {
    let dst = "s3://\(r2Bucket)/catalog.json"
    print("  Uploading catalog.json …")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: awsPath)
    p.arguments = ["s3", "cp", localURL.path, dst,
                   "--endpoint-url", r2Endpoint,
                   "--region", r2Region, "--no-progress",
                   "--content-type", "application/json"]
    p.environment = awsEnv()
    let errPipe = Pipe()
    p.standardOutput = Pipe()
    p.standardError  = errPipe
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = (try? errPipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw NSError(domain: "aws", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "catalog upload failed: \(msg)"])
    }
}

/// Merge analysis fields into catalog.json for each slug, then upload.
func updateCatalog(with analyses: [CatalogAnalysisFields], catalogLocalURL: URL) throws {
    let data = try Data(contentsOf: catalogLocalURL)
    guard var catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "catalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "catalog.json is not a JSON object"])
    }

    guard var tracks = catalog["tracks"] as? [[String: Any]] else {
        throw NSError(domain: "catalog", code: 2, userInfo: [NSLocalizedDescriptionKey: "catalog.json has no 'tracks' array"])
    }

    // Build lookup by slug
    var bySlug: [String: CatalogAnalysisFields] = [:]
    for a in analyses { bySlug[a.slug] = a }

    var updatedCount = 0
    for i in 0..<tracks.count {
        guard let id = tracks[i]["id"] as? String, let fields = bySlug[id] else { continue }
        tracks[i]["analyzed_at"]         = fields.analyzedAt
        tracks[i]["analyzer_version"]    = fields.analyzerVersion
        tracks[i]["dominant_categories"] = fields.dominantCategories
        tracks[i]["unique_label_count"]  = fields.uniqueLabelCount
        updatedCount += 1
    }

    catalog["tracks"] = tracks
    // Bump the updated timestamp
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    catalog["updated"] = fmt.string(from: Date())

    let outData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    try outData.write(to: catalogLocalURL)
    print("  Updated \(updatedCount)/\(analyses.count) track entries in catalog.json")
}

// MARK: - Entry point

func projectResultsDir() -> URL {
    // results/ next to the binary's parent (works for both dev and release)
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    // Walk up to find the project root (contains Package.swift)
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            return dir.appendingPathComponent("results")
        }
        dir = dir.deletingLastPathComponent()
    }
    // Fallback: current working dir / results
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("results")
}

func ensureDir(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

// MARK: - bulk-r2 subcommand

func runBulkR2(dryRun: Bool, force: Bool) async {
    print("=== bulk-r2 \(dryRun ? "(--dry-run)" : "") ===\n")

    // Step 1: List all bed.m4a slugs in R2
    print("Listing field-recording bed.m4a files in R2 …")
    let allBeds: [(key: String, slug: String, prefix: String)]
    do {
        allBeds = try listAllFieldRecordingBeds()
    } catch {
        fputs("FATAL: cannot list R2 objects: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    print("Found \(allBeds.count) bed.m4a file(s)\n")

    // Step 2: Idempotency check — skip slugs that already have events.json
    var toProcess: [(key: String, slug: String, prefix: String)] = []
    var skippedSlugs: [String] = []

    for bed in allBeds {
        let eventsKey = bed.prefix + "events.json"
        if !force && r2KeyExists(eventsKey) {
            skippedSlugs.append(bed.slug)
            print("  SKIP  \(bed.slug)  (events.json already in R2)")
        } else {
            toProcess.append(bed)
        }
    }

    print("\n\(toProcess.count) to process, \(skippedSlugs.count) already done.")

    // Apply 30-slug cap
    let cap = 30
    var remaining = 0
    if toProcess.count > cap {
        remaining = toProcess.count - cap
        toProcess = Array(toProcess.prefix(cap))
        print("Capping to \(cap) slugs this run. Remaining after run: \(remaining)")
    }

    if dryRun {
        print("\n[dry-run] Would process:")
        for (i, bed) in toProcess.enumerated() {
            print("  [\(i+1)/\(toProcess.count)] \(bed.slug)")
            print("           bed  → \(bed.key)")
            print("           events.json → \(bed.prefix)events.json")
        }
        if remaining > 0 {
            print("\nRemaining (beyond cap): \(remaining) slugs")
        }
        print("\n[dry-run] No files downloaded or uploaded.")
        return
    }

    // Step 3: Process each slug
    var catalogUpdates: [CatalogAnalysisFields] = []
    var totalEvents = 0

    for (i, bed) in toProcess.enumerated() {
        print("\n[\(i+1)/\(toProcess.count)] processing \(bed.slug)/")
        let tmpBed = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let tmpEvents = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "-events.json")

        // Download bed.m4a
        do {
            try downloadFromR2(r2Key: bed.key, to: tmpBed)
        } catch {
            fputs("  ERROR [\(bed.slug)] download failed: \(error.localizedDescription)\n", stderr)
            continue
        }

        // Analyze
        let result: AnalysisResult
        do {
            result = try await analyzeFile(
                url: tmpBed,
                source: bed.key,
                confidenceThreshold: 0.3
            )
        } catch {
            fputs("  ERROR [\(bed.slug)] analysis failed: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: tmpBed)
            continue
        }

        // Delete local temp bed immediately — don't fill disk
        try? FileManager.default.removeItem(at: tmpBed)

        // Write events.json locally
        do {
            try writeJSON(result, to: tmpEvents)
        } catch {
            fputs("  ERROR [\(bed.slug)] write events.json failed: \(error.localizedDescription)\n", stderr)
            continue
        }

        // Upload events.json to R2
        let eventsR2Key = bed.prefix + "events.json"
        do {
            try uploadToR2(localURL: tmpEvents, r2Key: eventsR2Key)
        } catch {
            fputs("  ERROR [\(bed.slug)] upload failed: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: tmpEvents)
            continue
        }
        try? FileManager.default.removeItem(at: tmpEvents)

        let eventCount = result.events.count
        totalEvents += eventCount
        let top5 = result.summary.topCategories.prefix(5).map(\.label)
        print("  → \(eventCount) events found → uploaded")
        print("    top: \(top5.joined(separator: ", "))")

        // Collect for catalog update
        catalogUpdates.append(CatalogAnalysisFields(
            slug: bed.slug,
            analyzedAt: result.analyzedAt,
            analyzerVersion: result.analyzerVersion,
            dominantCategories: Array(top5),
            uniqueLabelCount: result.summary.uniqueLabels
        ))
    }

    // Step 4: Update catalog.json (single merge at end)
    if !catalogUpdates.isEmpty {
        print("\n=== Updating catalog.json ===")
        let tmpCatalog = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-bulk-r2-\(UUID().uuidString).json")
        do {
            try downloadCatalog(to: tmpCatalog)
            try updateCatalog(with: catalogUpdates, catalogLocalURL: tmpCatalog)
            try uploadCatalog(from: tmpCatalog)
            try? FileManager.default.removeItem(at: tmpCatalog)
            print("  catalog.json updated with \(catalogUpdates.count) slug(s)")
        } catch {
            fputs("ERROR updating catalog.json: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: tmpCatalog)
        }
    }

    print("\n=== bulk-r2 complete ===")
    print("Processed: \(catalogUpdates.count)/\(toProcess.count) slugs")
    print("Total events across all uploads: \(totalEvents)")
    if remaining > 0 {
        print("Remaining (run again to continue): \(remaining) slugs")
    }
}

// MARK: - Argument parsing & dispatch

let args = CommandLine.arguments.dropFirst()

enum Mode {
    case localFile(URL)
    case r2Prefix(String)
    case allFieldRecordings
    case bulkR2(dryRun: Bool, force: Bool)
}

func parseMode() -> Mode? {
    let argList = Array(args)
    guard !argList.isEmpty else { return nil }

    // bulk-r2 subcommand
    if argList[0] == "bulk-r2" {
        let dryRun = argList.contains("--dry-run")
        let force  = argList.contains("--force")
        return .bulkR2(dryRun: dryRun, force: force)
    }

    if argList[0] == "--all-field-recordings" {
        return .allFieldRecordings
    }
    if argList[0] == "--r2-prefix" && argList.count >= 2 {
        return .r2Prefix(argList[1])
    }
    // Otherwise treat as local file path or R2 key
    let first = argList[0]
    if first.hasPrefix("stems/") || first.hasPrefix("s3://") {
        // R2 key (strip leading s3://cloud-to-float-on/ if present)
        let key = first
            .replacingOccurrences(of: "s3://\(r2Bucket)/", with: "")
        return .r2Prefix(key.hasSuffix("/") ? key : key + "/")
    }
    return .localFile(URL(fileURLWithPath: first))
}

guard let mode = parseMode() else {
    print("""
    usage:
      analyze-bed <local-path>                               # analyze a local bed.m4a
      analyze-bed <r2-key-prefix>                            # e.g. stems/spatial-mix/.../<slug>/
      analyze-bed --r2-prefix <prefix>                       # same
      analyze-bed --all-field-recordings                     # process everything in R2 (local output only)
      analyze-bed bulk-r2 [--dry-run] [--force]              # bulk: analyze R2, upload events.json, update catalog
    """)
    exit(1)
}

// bulk-r2 path — dispatch and exit
if case .bulkR2(let dryRun, let force) = mode {
    await runBulkR2(dryRun: dryRun, force: force)
    exit(0)
}

// ---- Legacy single/multi-file local paths below ----

// Collect (r2Key?, localURL, slug, outputURL)
struct Job {
    var r2Key: String?
    var localURL: URL
    var slug: String
    var outputURL: URL
}

let resultsDir = projectResultsDir()
ensureDir(resultsDir)

var jobs: [Job] = []

switch mode {
case .localFile(let url):
    let slug = url.deletingPathExtension().lastPathComponent
    let outputURL = resultsDir.appendingPathComponent("\(slug).events.json")
    jobs.append(Job(r2Key: nil, localURL: url, slug: slug, outputURL: outputURL))

case .r2Prefix(let prefix):
    let key = prefix.hasSuffix("bed.m4a") ? prefix : prefix + "bed.m4a"
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".m4a")
    let parts = prefix.components(separatedBy: "/")
    let slug  = parts.filter { !$0.isEmpty }.last ?? "unknown"
    let outputURL = resultsDir.appendingPathComponent("\(slug).events.json")
    jobs.append(Job(r2Key: key, localURL: tmp, slug: slug, outputURL: outputURL))

case .allFieldRecordings:
    print("Listing all field-recording bed.m4a files in R2 …")
    let beds = try listAllFieldRecordingBeds()
    print("Found \(beds.count) bed.m4a file(s)\n")
    for bed in beds {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".m4a")
        let outputURL = resultsDir.appendingPathComponent("\(bed.slug).events.json")
        jobs.append(Job(r2Key: bed.key, localURL: tmp, slug: bed.slug, outputURL: outputURL))
    }

case .bulkR2:
    // handled above
    break
}

// Run all jobs
var allResults: [AnalysisResult] = []

for (i, job) in jobs.enumerated() {
    print("\n[\(i+1)/\(jobs.count)] \(job.slug)")

    // Download from R2 if needed
    if let key = job.r2Key {
        do {
            try downloadFromR2(r2Key: key, to: job.localURL)
        } catch {
            print("  ERROR downloading: \(error.localizedDescription)")
            continue
        }
    }

    defer {
        // Clean up temp file
        if job.r2Key != nil {
            try? FileManager.default.removeItem(at: job.localURL)
        }
    }

    do {
        let result = try await analyzeFile(url: job.localURL,
                                           source: job.r2Key ?? job.localURL.path,
                                           confidenceThreshold: 0.3)
        try writeJSON(result, to: job.outputURL)
        allResults.append(result)

        print("  Written: \(job.outputURL.path)")
        print("  Top categories:")
        for cat in result.summary.topCategories.prefix(5) {
            print("    \(cat.label): \(cat.totalSeconds)s (\(cat.eventCount) events)")
        }
    } catch {
        print("  ERROR analyzing: \(error.localizedDescription)")
    }
}

// MARK: - Aggregate summary across all files

if allResults.count > 1 {
    print("\n\n=== AGGREGATE ACROSS ALL FILES ===")
    var aggregate: [String: (totalSec: Double, count: Int)] = [:]
    for r in allResults {
        for cat in r.summary.topCategories {
            aggregate[cat.label, default: (0, 0)].totalSec += cat.totalSeconds
            aggregate[cat.label, default: (0, 0)].count    += cat.eventCount
        }
    }
    let sorted = aggregate.sorted { $0.value.totalSec > $1.value.totalSec }
    print("Top 15 labels by total seconds:")
    for (i, item) in sorted.prefix(15).enumerated() {
        print("  \(i+1). \(item.key): \(Int(item.value.totalSec))s (\(item.value.count) events)")
    }
    print("\nTotal events: \(allResults.reduce(0) { $0 + $1.events.count })")
    print("Unique labels: \(aggregate.count)")
}

print("\nDone. Results in: \(resultsDir.path)")
