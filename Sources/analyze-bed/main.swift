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

// MARK: - Bird label set (inclusive — used to identify windows for species pass)

private let birdLabels: Set<String> = [
    "bird", "bird_vocalization", "bird_chirp", "bird_chirp_tweet", "bird_squawk",
    "bird_song", "songbird", "owl_hoot", "whistling", "chirp", "parrot"
]

func isBirdLabel(_ label: String) -> Bool {
    birdLabels.contains(label.lowercased())
}

// MARK: - Data models

struct ClassificationEvent: Codable {
    let startSec: Double
    let endSec: Double
    let label: String
    let confidence: Double
    // Optional species fields (only set for BirdNET events)
    let source: String?
    let speciesCommon: String?
    let speciesScientific: String?

    enum CodingKeys: String, CodingKey {
        case startSec          = "start_sec"
        case endSec            = "end_sec"
        case label
        case confidence
        case source
        case speciesCommon     = "species_common"
        case speciesScientific = "species_scientific"
    }

    // Apple SoundAnalysis event (no source/species fields)
    init(startSec: Double, endSec: Double, label: String, confidence: Double) {
        self.startSec          = startSec
        self.endSec            = endSec
        self.label             = label
        self.confidence        = confidence
        self.source            = nil
        self.speciesCommon     = nil
        self.speciesScientific = nil
    }

    // BirdNET species event
    init(startSec: Double, endSec: Double, speciesCommon: String,
         speciesScientific: String, confidence: Double) {
        self.startSec          = startSec
        self.endSec            = endSec
        self.label             = "species_detection"
        self.confidence        = confidence
        self.source            = "birdnet"
        self.speciesCommon     = speciesCommon
        self.speciesScientific = speciesScientific
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startSec, forKey: .startSec)
        try container.encode(endSec,   forKey: .endSec)
        try container.encode(label,    forKey: .label)
        try container.encode(confidence, forKey: .confidence)
        if let source = source            { try container.encode(source,            forKey: .source) }
        if let sc = speciesCommon         { try container.encode(sc,                forKey: .speciesCommon) }
        if let ss = speciesScientific     { try container.encode(ss,                forKey: .speciesScientific) }
    }
}

struct SpeciesRecord {
    let common: String
    let scientific: String
    var eventCount: Int
    var maxConfidence: Double
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
        case durationSec     = "duration_sec"
        case analyzerVersion = "analyzer_version"
        case analyzedAt      = "analyzed_at"
        case events
        case summary
        case confoundsNote   = "confounds_note"
    }

    struct Summary: Codable {
        let topCategories: [Category]
        let uniqueLabels: Int
        let medianEventDurationSec: Double
        let speciesDetected: [SpeciesSummary]?
        let speciesCount: Int?

        enum CodingKeys: String, CodingKey {
            case topCategories          = "top_categories"
            case uniqueLabels           = "unique_labels"
            case medianEventDurationSec = "median_event_duration_sec"
            case speciesDetected        = "species_detected"
            case speciesCount           = "species_count"
        }

        init(topCategories: [Category], uniqueLabels: Int,
             medianEventDurationSec: Double,
             speciesDetected: [SpeciesSummary]? = nil,
             speciesCount: Int? = nil) {
            self.topCategories          = topCategories
            self.uniqueLabels           = uniqueLabels
            self.medianEventDurationSec = medianEventDurationSec
            self.speciesDetected        = speciesDetected
            self.speciesCount           = speciesCount
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

        struct SpeciesSummary: Codable {
            let common: String
            let scientific: String
            let eventCount: Int
            let maxConfidence: Double

            enum CodingKeys: String, CodingKey {
                case common
                case scientific
                case eventCount   = "event_count"
                case maxConfidence = "max_confidence"
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
                clusterEnd = max(clusterEnd, rEnd)
                confidences.append(r.confidence)
            } else {
                let meanConf = confidences.reduce(0, +) / Double(confidences.count)
                events.append(ClassificationEvent(startSec: clusterStart,
                                                  endSec: clusterEnd,
                                                  label: clusterLabel,
                                                  confidence: (meanConf * 1000).rounded() / 1000))
                clusterLabel = r.label
                clusterStart = r.timeSec
                clusterEnd   = rEnd
                confidences  = [r.confidence]
            }
        }
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

func buildSummary(from events: [ClassificationEvent],
                  speciesRecords: [SpeciesRecord]? = nil) -> AnalysisResult.Summary {
    // Only count Apple events for top_categories
    let appleEvents = events.filter { $0.source == nil }
    var byLabel: [String: (totalSec: Double, count: Int)] = [:]
    for e in appleEvents {
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
    let durations = appleEvents.map { $0.endSec - $0.startSec }

    // Species summary
    var speciesSummaries: [AnalysisResult.Summary.SpeciesSummary]? = nil
    var speciesCount: Int? = nil
    if let records = speciesRecords {
        let sorted = records.sorted { $0.maxConfidence > $1.maxConfidence }
        speciesSummaries = sorted.map {
            AnalysisResult.Summary.SpeciesSummary(
                common: $0.common,
                scientific: $0.scientific,
                eventCount: $0.eventCount,
                maxConfidence: ($0.maxConfidence * 1000).rounded() / 1000
            )
        }
        speciesCount = records.count
    }

    return AnalysisResult.Summary(
        topCategories: top,
        uniqueLabels: byLabel.count,
        medianEventDurationSec: (median(durations) * 100).rounded() / 100,
        speciesDetected: speciesSummaries,
        speciesCount: speciesCount
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
    p.standardOutput = Pipe()
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

// MARK: - Location hinting for BirdNET

/// Returns (lat, lon, dateString) best guess for a given slug.
/// Slug names matching "backyard", "woodland-hills", or US keywords → US Bay Area coords.
/// Everything else → Brazil center (default for H8 field recordings from Brazil trip).
func locationHint(slug: String, prefix: String) -> (lat: Double, lon: Double) {
    let lower = slug.lowercased()
    let usKeywords = ["backyard", "woodland-hills", "woodland_hills", "los-angeles", "la-"]
    for kw in usKeywords where lower.contains(kw) {
        return (lat: 34.168, lon: -118.601)  // Woodland Hills, LA
    }
    // Brazil center default
    return (lat: -15.0, lon: -50.0)
}

/// Extract a date string from a slug, e.g. "2024-10-19" from "mic1234-2024-10-19-ff4d86"
func datehintFromSlug(_ slug: String) -> String {
    // Look for YYYY-MM-DD pattern in slug
    let pattern = #"\d{4}-\d{2}-\d{2}"#
    if let range = slug.range(of: pattern, options: .regularExpression) {
        return String(slug[range])
    }
    // Fall back to today
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: Date())
}

// MARK: - BirdNET Python subprocess

/// Resolve the Python interpreter path for the project-local species venv.
func speciesPythonPath() -> String {
    // Walk up from binary to find project root (contains Package.swift)
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<8 {
        let pkgSwift = dir.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkgSwift.path) {
            let venvPython = dir.appendingPathComponent(".species-env/bin/python3").path
            if FileManager.default.fileExists(atPath: venvPython) {
                return venvPython
            }
        }
        dir = dir.deletingLastPathComponent()
    }
    // Fallback: system python3
    return "/usr/bin/python3"
}

/// Resolve path to birdnet_analyze.py helper script.
func birdnetScriptPath() -> String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<8 {
        let pkgSwift = dir.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkgSwift.path) {
            return dir.appendingPathComponent("Sources/analyze-bed/birdnet_analyze.py").path
        }
        dir = dir.deletingLastPathComponent()
    }
    return "birdnet_analyze.py"
}

struct BirdNetDetection {
    let common: String
    let scientific: String
    let startSec: Double
    let endSec: Double
    let confidence: Double
}

/// Run BirdNET on audioFile, returning detections with confidence >= 0.5.
/// Passes bird window time ranges to Python so it only keeps detections overlapping those windows.
func runBirdNet(audioURL: URL,
                birdWindows: [(start: Double, end: Double)],
                slug: String,
                prefix: String) -> [BirdNetDetection] {
    guard !birdWindows.isEmpty else { return [] }

    let python = speciesPythonPath()
    let script = birdnetScriptPath()
    let loc     = locationHint(slug: slug, prefix: prefix)
    let date    = datehintFromSlug(slug)
    let tmpOut  = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString + "-birdnet.json")
    defer { try? FileManager.default.removeItem(at: tmpOut) }

    print("  [BirdNET] Running species classifier (lat=\(loc.lat), lon=\(loc.lon), date=\(date)) …")
    print("  [BirdNET] Bird windows: \(birdWindows.count), python=\(python)")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    // Pass the full file — BirdNET segments internally; we filter by window in post
    p.arguments = [script, audioURL.path, tmpOut.path,
                   String(loc.lat), String(loc.lon), date]
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError  = errPipe
    do {
        try p.run()
    } catch {
        fputs("  [BirdNET] Failed to launch Python: \(error.localizedDescription)\n", stderr)
        return []
    }
    p.waitUntilExit()

    // Echo BirdNET stdout for monitoring
    if let outData = try? outPipe.fileHandleForReading.readToEnd(),
       let outStr  = String(data: outData, encoding: .utf8), !outStr.isEmpty {
        outStr.components(separatedBy: "\n").forEach {
            if !$0.isEmpty { print("  [BirdNET] \($0)") }
        }
    }

    if p.terminationStatus != 0 {
        if let errData = try? errPipe.fileHandleForReading.readToEnd(),
           let errStr  = String(data: errData, encoding: .utf8) {
            fputs("  [BirdNET] ERROR (exit \(p.terminationStatus)):\n\(errStr)\n", stderr)
        }
        return []
    }

    // Parse JSON output from Python
    guard let jsonData = try? Data(contentsOf: tmpOut),
          let rawList  = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
    else {
        fputs("  [BirdNET] Could not read output JSON\n", stderr)
        return []
    }

    var detections: [BirdNetDetection] = []
    for item in rawList {
        guard let common  = item["common"]     as? String,
              let sci     = item["scientific"]  as? String,
              let start   = item["start_sec"]   as? Double,
              let end     = item["end_sec"]     as? Double,
              let conf    = item["confidence"]  as? Double,
              conf >= 0.5
        else { continue }

        // Filter: only keep detections whose window overlaps a bird-flagged Apple window
        let overlaps = birdWindows.contains { w in
            start < w.end && end > w.start
        }
        if overlaps {
            detections.append(BirdNetDetection(
                common: common, scientific: sci,
                startSec: start, endSec: end, confidence: conf
            ))
        }
    }

    print("  [BirdNET] \(detections.count) species detections (filtered to bird windows)")
    return detections
}

/// Aggregate detections into per-species records (for summary).
func aggregateSpecies(_ detections: [BirdNetDetection]) -> [SpeciesRecord] {
    var bySpecies: [String: SpeciesRecord] = [:]
    for d in detections {
        let key = d.scientific
        if var existing = bySpecies[key] {
            existing.eventCount    += 1
            existing.maxConfidence  = max(existing.maxConfidence, d.confidence)
            bySpecies[key] = existing
        } else {
            bySpecies[key] = SpeciesRecord(common: d.common, scientific: d.scientific,
                                           eventCount: 1, maxConfidence: d.confidence)
        }
    }
    return Array(bySpecies.values).sorted { $0.maxConfidence > $1.maxConfidence }
}

// MARK: - Core analyzer

func analyzeFile(url: URL, source: String, confidenceThreshold: Double,
                 withSpecies: Bool, slug: String, prefix: String) async throws -> AnalysisResult {
    print("  Decoding to 16 kHz mono WAV via ffmpeg …")
    let wavURL = try decodeTo16kMono(inputURL: url)
    defer { try? FileManager.default.removeItem(at: wavURL) }

    let audioFile = try AVAudioFile(forReading: wavURL)
    let format    = audioFile.processingFormat
    let frameCount = AVAudioFrameCount(audioFile.length)

    print("  Audio: \(format.sampleRate) Hz, \(format.channelCount) ch, \(frameCount) frames")

    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "analyzer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot allocate PCM buffer"])
    }
    try audioFile.read(into: pcmBuffer)
    pcmBuffer.frameLength = frameCount

    let durationSec = Double(frameCount) / format.sampleRate

    let streamAnalyzer = SNAudioStreamAnalyzer(format: format)
    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
    request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: CMTimeScale(format.sampleRate))
    request.overlapFactor = 0.5

    let observer = ClassificationObserver()
    observer.confidenceThreshold = confidenceThreshold
    try streamAnalyzer.add(request, withObserver: observer)

    let chunkFrames: AVAudioFrameCount = 16000 * 10
    var frameOffset: AVAudioFramePosition = 0
    var chunksProcessed = 0
    let totalChunks = Int((Double(frameCount) / Double(chunkFrames)).rounded(.up))

    print("  Analyzing \(totalChunks) chunks (10 s each) …")

    while frameOffset < AVAudioFramePosition(frameCount) {
        let remaining = AVAudioFrameCount(AVAudioFramePosition(frameCount) - frameOffset)
        let thisChunk = min(chunkFrames, remaining)

        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisChunk) else { break }
        chunk.frameLength = thisChunk

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

    var appleEvents: [ClassificationEvent]
    if rawCount == 0 && confidenceThreshold > 0.1 {
        print("  No results above \(confidenceThreshold) — retrying with threshold 0.1")
        let streamAnalyzer2 = SNAudioStreamAnalyzer(format: format)
        let request2 = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request2.windowDuration = CMTime(seconds: 0.975, preferredTimescale: CMTimeScale(format.sampleRate))
        request2.overlapFactor  = 0.5
        let observer2 = ClassificationObserver()
        observer2.confidenceThreshold = 0.1
        try streamAnalyzer2.add(request2, withObserver: observer2)
        try streamAnalyzer2.analyze(pcmBuffer, atAudioFramePosition: 0)
        streamAnalyzer2.completeAnalysis()
        print("  Raw windows at 0.1 threshold: \(observer2.rawResults.count)")
        appleEvents = observer2.clusterEvents()
    } else {
        appleEvents = observer.clusterEvents()
    }

    print("  Clustered events: \(appleEvents.count)")

    // MARK: — Species pass
    var allEvents: [ClassificationEvent] = appleEvents
    var speciesRecords: [SpeciesRecord]? = nil

    if withSpecies {
        // Identify bird-flagged windows from Apple's output
        let birdWindows = appleEvents
            .filter { isBirdLabel($0.label) }
            .map { (start: $0.startSec, end: $0.endSec) }

        if birdWindows.isEmpty {
            print("  [BirdNET] No bird-flagged windows found — skipping species pass")
        } else {
            print("  [BirdNET] \(birdWindows.count) bird window(s) to re-classify …")
            // Pass ORIGINAL m4a to BirdNET — it handles its own resampling
            let detections = runBirdNet(audioURL: url, birdWindows: birdWindows,
                                        slug: slug, prefix: prefix)
            // Convert to ClassificationEvent
            let speciesEvents = detections.map { d in
                ClassificationEvent(startSec: d.startSec, endSec: d.endSec,
                                    speciesCommon: d.common, speciesScientific: d.scientific,
                                    confidence: (d.confidence * 1000).rounded() / 1000)
            }
            allEvents.append(contentsOf: speciesEvents)
            speciesRecords = aggregateSpecies(detections)

            let uniqueCount = speciesRecords?.count ?? 0
            print("  [BirdNET] \(speciesEvents.count) species events, \(uniqueCount) unique species")
        }
    }

    let summary = buildSummary(from: allEvents, speciesRecords: speciesRecords)
    let analyzerVersion = withSpecies
        ? "apple-soundanalysis-v1+birdnet-v2.4"
        : "apple-soundanalysis-v1"

    return AnalysisResult(
        source: source,
        durationSec: (durationSec * 10).rounded() / 10,
        analyzerVersion: analyzerVersion,
        analyzedAt: iso8601Now(),
        events: allEvents,
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
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { continue }
        let key = String(parts[3])
        guard key.hasSuffix("/bed.m4a") else { continue }
        let prefix = String(key.dropLast("bed.m4a".count))
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
    let speciesList: [String]?
    let speciesCount: Int?
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

func updateCatalog(with analyses: [CatalogAnalysisFields], catalogLocalURL: URL) throws {
    let data = try Data(contentsOf: catalogLocalURL)
    guard var catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "catalog", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "catalog.json is not a JSON object"])
    }

    guard var tracks = catalog["tracks"] as? [[String: Any]] else {
        throw NSError(domain: "catalog", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "catalog.json has no 'tracks' array"])
    }

    var bySlug: [String: CatalogAnalysisFields] = [:]
    for a in analyses { bySlug[a.slug] = a }

    var updatedCount = 0
    for i in 0..<tracks.count {
        guard let id = tracks[i]["id"] as? String, let fields = bySlug[id] else { continue }
        tracks[i]["analyzed_at"]         = fields.analyzedAt
        tracks[i]["analyzer_version"]    = fields.analyzerVersion
        tracks[i]["dominant_categories"] = fields.dominantCategories
        tracks[i]["unique_label_count"]  = fields.uniqueLabelCount
        if let sl = fields.speciesList  { tracks[i]["species_list"]  = sl }
        if let sc = fields.speciesCount { tracks[i]["species_count"] = sc }
        updatedCount += 1
    }

    catalog["tracks"] = tracks
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    catalog["updated"] = fmt.string(from: Date())

    let outData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    try outData.write(to: catalogLocalURL)
    print("  Updated \(updatedCount)/\(analyses.count) track entries in catalog.json")
}

// MARK: - Entry point helpers

func projectResultsDir() -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            return dir.appendingPathComponent("results")
        }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("results")
}

func ensureDir(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

// MARK: - bulk-r2 subcommand

func runBulkR2(dryRun: Bool, force: Bool, withSpecies: Bool) async {
    let speciesLabel = withSpecies ? " +species" : ""
    print("=== bulk-r2\(speciesLabel) \(dryRun ? "(--dry-run)" : "") ===\n")

    print("Listing field-recording bed.m4a files in R2 …")
    let allBeds: [(key: String, slug: String, prefix: String)]
    do {
        allBeds = try listAllFieldRecordingBeds()
    } catch {
        fputs("FATAL: cannot list R2 objects: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    print("Found \(allBeds.count) bed.m4a file(s)\n")

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

    var catalogUpdates: [CatalogAnalysisFields] = []
    var totalEvents = 0
    var totalSpeciesEvents = 0

    for (i, bed) in toProcess.enumerated() {
        print("\n[\(i+1)/\(toProcess.count)] processing \(bed.slug)/")
        let tmpBed = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let tmpEvents = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "-events.json")

        do {
            try downloadFromR2(r2Key: bed.key, to: tmpBed)
        } catch {
            fputs("  ERROR [\(bed.slug)] download failed: \(error.localizedDescription)\n", stderr)
            continue
        }

        let result: AnalysisResult
        do {
            result = try await analyzeFile(
                url: tmpBed,
                source: bed.key,
                confidenceThreshold: 0.3,
                withSpecies: withSpecies,
                slug: bed.slug,
                prefix: bed.prefix
            )
        } catch {
            fputs("  ERROR [\(bed.slug)] analysis failed: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: tmpBed)
            continue
        }

        try? FileManager.default.removeItem(at: tmpBed)

        do {
            try writeJSON(result, to: tmpEvents)
        } catch {
            fputs("  ERROR [\(bed.slug)] write events.json failed: \(error.localizedDescription)\n", stderr)
            continue
        }

        let eventsR2Key = bed.prefix + "events.json"
        do {
            try uploadToR2(localURL: tmpEvents, r2Key: eventsR2Key)
        } catch {
            fputs("  ERROR [\(bed.slug)] upload failed: \(error.localizedDescription)\n", stderr)
            try? FileManager.default.removeItem(at: tmpEvents)
            continue
        }
        try? FileManager.default.removeItem(at: tmpEvents)

        // Count event types
        let appleEventCount   = result.events.filter { $0.source == nil }.count
        let speciesEventCount = result.events.filter { $0.source == "birdnet" }.count
        totalEvents        += appleEventCount
        totalSpeciesEvents += speciesEventCount

        let top5 = result.summary.topCategories.prefix(5).map(\.label)
        print("  → \(appleEventCount) Apple events + \(speciesEventCount) species events → uploaded")
        print("    top Apple: \(top5.joined(separator: ", "))")

        // Print spot-check for species
        if withSpecies, let speciesSummary = result.summary.speciesDetected, !speciesSummary.isEmpty {
            let top3 = speciesSummary.prefix(3).map { "\($0.common) (\(String(format: "%.2f", $0.maxConfidence)))" }
            print("    top species: \(top3.joined(separator: " | "))")
            print("    species total: \(result.summary.speciesCount ?? 0) unique")
        }

        // Species list for catalog
        let speciesList = result.summary.speciesDetected.map { summaries in
            summaries.prefix(10).map(\.common)
        }

        catalogUpdates.append(CatalogAnalysisFields(
            slug: bed.slug,
            analyzedAt: result.analyzedAt,
            analyzerVersion: result.analyzerVersion,
            dominantCategories: Array(top5),
            uniqueLabelCount: result.summary.uniqueLabels,
            speciesList: speciesList.map(Array.init),
            speciesCount: result.summary.speciesCount
        ))
    }

    // Catalog update
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
    print("Total Apple events: \(totalEvents)")
    if withSpecies {
        print("Total species events: \(totalSpeciesEvents)")
    }
    if remaining > 0 {
        print("Remaining (run again to continue): \(remaining) slugs")
    }

    // Spot-check summary
    if withSpecies {
        print("\n=== SPOT-CHECK SUMMARY ===")
        for update in catalogUpdates {
            let sl = update.speciesList?.joined(separator: ", ") ?? "none"
            let sc = update.speciesCount.map { "\($0)" } ?? "0"
            print("  \(update.slug): \(sc) species — \(sl)")
        }
    }
}

// MARK: - Argument parsing & dispatch

let args = CommandLine.arguments.dropFirst()

enum Mode {
    case localFile(URL)
    case r2Prefix(String)
    case allFieldRecordings
    case bulkR2(dryRun: Bool, force: Bool, withSpecies: Bool)
}

func parseMode() -> Mode? {
    let argList = Array(args)
    guard !argList.isEmpty else { return nil }

    if argList[0] == "bulk-r2" {
        let dryRun     = argList.contains("--dry-run")
        let force      = argList.contains("--force")
        let withSpecies = argList.contains("--with-species")
        return .bulkR2(dryRun: dryRun, force: force, withSpecies: withSpecies)
    }

    if argList[0] == "--all-field-recordings" {
        return .allFieldRecordings
    }
    if argList[0] == "--r2-prefix" && argList.count >= 2 {
        return .r2Prefix(argList[1])
    }
    let first = argList[0]
    if first.hasPrefix("stems/") || first.hasPrefix("s3://") {
        let key = first
            .replacingOccurrences(of: "s3://\(r2Bucket)/", with: "")
        return .r2Prefix(key.hasSuffix("/") ? key : key + "/")
    }
    return .localFile(URL(fileURLWithPath: first))
}

guard let mode = parseMode() else {
    print("""
    usage:
      analyze-bed <local-path>                                         # analyze a local bed.m4a
      analyze-bed <r2-key-prefix>                                      # e.g. stems/spatial-mix/.../<slug>/
      analyze-bed --r2-prefix <prefix>                                 # same
      analyze-bed --all-field-recordings                               # process everything in R2 (local output only)
      analyze-bed bulk-r2 [--dry-run] [--force] [--with-species]      # bulk: analyze R2, upload events.json + catalog
    """)
    exit(1)
}

if case .bulkR2(let dryRun, let force, let withSpecies) = mode {
    await runBulkR2(dryRun: dryRun, force: force, withSpecies: withSpecies)
    exit(0)
}

// ---- Legacy single/multi-file local paths below ----

struct Job {
    var r2Key: String?
    var localURL: URL
    var slug: String
    var outputURL: URL
    var prefix: String
}

let resultsDir = projectResultsDir()
ensureDir(resultsDir)

var jobs: [Job] = []

switch mode {
case .localFile(let url):
    let slug = url.deletingPathExtension().lastPathComponent
    let outputURL = resultsDir.appendingPathComponent("\(slug).events.json")
    jobs.append(Job(r2Key: nil, localURL: url, slug: slug, outputURL: outputURL, prefix: ""))

case .r2Prefix(let prefix):
    let key = prefix.hasSuffix("bed.m4a") ? prefix : prefix + "bed.m4a"
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".m4a")
    let parts = prefix.components(separatedBy: "/")
    let slug  = parts.filter { !$0.isEmpty }.last ?? "unknown"
    let outputURL = resultsDir.appendingPathComponent("\(slug).events.json")
    jobs.append(Job(r2Key: key, localURL: tmp, slug: slug, outputURL: outputURL, prefix: prefix))

case .allFieldRecordings:
    print("Listing all field-recording bed.m4a files in R2 …")
    let beds = try listAllFieldRecordingBeds()
    print("Found \(beds.count) bed.m4a file(s)\n")
    for bed in beds {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".m4a")
        let outputURL = resultsDir.appendingPathComponent("\(bed.slug).events.json")
        jobs.append(Job(r2Key: bed.key, localURL: tmp, slug: bed.slug, outputURL: outputURL, prefix: bed.prefix))
    }

case .bulkR2:
    break
}

// Run all jobs (local paths — no species pass in legacy mode)
var allResults: [AnalysisResult] = []

for (i, job) in jobs.enumerated() {
    print("\n[\(i+1)/\(jobs.count)] \(job.slug)")

    if let key = job.r2Key {
        do {
            try downloadFromR2(r2Key: key, to: job.localURL)
        } catch {
            print("  ERROR downloading: \(error.localizedDescription)")
            continue
        }
    }

    defer {
        if job.r2Key != nil {
            try? FileManager.default.removeItem(at: job.localURL)
        }
    }

    do {
        let result = try await analyzeFile(url: job.localURL,
                                           source: job.r2Key ?? job.localURL.path,
                                           confidenceThreshold: 0.3,
                                           withSpecies: false,
                                           slug: job.slug,
                                           prefix: job.prefix)
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
