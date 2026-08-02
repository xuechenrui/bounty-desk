import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift render_terminal_session.swift SESSION OUTPUT.mp4")
}

let sessionURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let marker = "___BOUNTY_DESK_TIMESTAMP_"

let replay = Process()
replay.executableURL = URL(fileURLWithPath: "/usr/bin/script")
replay.arguments = ["-p", "-T", "\(marker)%s___", sessionURL.path]
let replayOutput = Pipe()
let replayError = Pipe()
replay.standardOutput = replayOutput
replay.standardError = replayError

do {
    try replay.run()
} catch {
    fail("could not replay terminal session: \(error)")
}
let replayData = replayOutput.fileHandleForReading.readDataToEndOfFile()
replay.waitUntilExit()
guard replay.terminationStatus == 0 else {
    let detail = String(data: replayError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    fail("terminal replay failed: \(detail)")
}
guard var replayText = String(data: replayData, encoding: .utf8) else {
    fail("terminal replay is not UTF-8")
}

let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
let ansiRegex = try NSRegularExpression(pattern: ansiPattern)
replayText = ansiRegex.stringByReplacingMatches(
    in: replayText,
    range: NSRange(replayText.startIndex..., in: replayText),
    withTemplate: ""
)
replayText = replayText.replacingOccurrences(of: "\u{0004}\u{0008}\u{0008}", with: "")
replayText = replayText.replacingOccurrences(of: "\r\n", with: "\n")
replayText = replayText.replacingOccurrences(of: "\r", with: "\n")

let eventPattern = NSRegularExpression.escapedPattern(for: marker) + #"([0-9]+)___"#
let eventRegex = try NSRegularExpression(pattern: eventPattern)
let fullRange = NSRange(replayText.startIndex..., in: replayText)
let matches = eventRegex.matches(in: replayText, range: fullRange)
guard !matches.isEmpty else { fail("terminal replay did not contain timestamp records") }

struct Event {
    let timestamp: Int
    let text: String
}

var events: [Event] = []
for (index, match) in matches.enumerated() {
    guard let timestampRange = Range(match.range(at: 1), in: replayText),
          let timestamp = Int(replayText[timestampRange]) else {
        fail("invalid replay timestamp")
    }
    let contentStart = match.range.location + match.range.length
    let contentEnd = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.length
    guard let contentRange = Range(NSRange(location: contentStart, length: contentEnd - contentStart), in: replayText) else {
        fail("invalid replay content range")
    }
    events.append(Event(timestamp: timestamp, text: String(replayText[contentRange])))
}

let firstTimestamp = events[0].timestamp
let lastTimestamp = events.last?.timestamp ?? firstTimestamp
let totalSeconds = max(3, lastTimestamp - firstTimestamp + 3)
let width = 1920
let height = 1080
let fps = 12
let totalFrames = totalSeconds * fps
let visibleLineCount = 26
let wrapColumns = 108

func wrappedLines(_ raw: String) -> [String] {
    var result: [String] = []
    for logicalLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        var remaining = String(logicalLine)
        if remaining.isEmpty {
            result.append("")
            continue
        }
        while remaining.count > wrapColumns {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: wrapColumns)
            result.append(String(remaining[..<splitIndex]))
            remaining = "  " + String(remaining[splitIndex...])
        }
        result.append(remaining)
    }
    return result
}

func lineColor(_ line: String) -> NSColor {
    if line.hasPrefix("$ ") { return NSColor(calibratedRed: 0.31, green: 0.91, blue: 0.66, alpha: 1) }
    if line.range(of: #"^[1-5]\. "#, options: .regularExpression) != nil {
        return NSColor(calibratedRed: 0.40, green: 0.83, blue: 0.98, alpha: 1)
    }
    if line.contains("HTTP 401") || line.contains("failed closed") {
        return NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.45, alpha: 1)
    }
    if line.contains("HTTP 200") || line.contains("PASS:") || line.contains("\"verified\": true") {
        return NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.55, alpha: 1)
    }
    if line.contains("https://") || line.contains("solana:") {
        return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.36, alpha: 1)
    }
    return NSColor(calibratedWhite: 0.90, alpha: 1)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: outputURL)
guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
    fail("could not create video writer")
}
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 3_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
]
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
writerInput.expectsMediaDataInRealTime = false
let pixelAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: writerInput,
    sourcePixelBufferAttributes: pixelAttributes
)
guard writer.canAdd(writerInput) else { fail("video writer rejected input") }
writer.add(writerInput)
guard writer.startWriting() else { fail(writer.error?.localizedDescription ?? "video writer failed") }
writer.startSession(atSourceTime: .zero)

let terminalFont = NSFont.monospacedSystemFont(ofSize: 27, weight: .regular)
let terminalBold = NSFont.monospacedSystemFont(ofSize: 27, weight: .semibold)
let titleFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
let smallFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)

func drawFrame(lines: [String], elapsed: Double) -> CVPixelBuffer {
    var optionalBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        pixelAttributes as CFDictionary,
        &optionalBuffer
    )
    guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
        fail("could not create pixel buffer")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { fail("could not create drawing context") }

    context.setFillColor(CGColor(red: 0.035, green: 0.055, blue: 0.105, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.065, green: 0.095, blue: 0.16, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 72, width: width, height: 72))

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    let title = "BountyDesk · REAL ZEROCLAW × SOLANA TERMINAL RUN"
    (title as NSString).draw(
        at: NSPoint(x: 48, y: height - 50),
        withAttributes: [.font: titleFont, .foregroundColor: NSColor.white]
    )
    let badge = "LIVE REPLAY  \(String(format: "%05.1fs", elapsed))"
    (badge as NSString).draw(
        at: NSPoint(x: width - 330, y: height - 47),
        withAttributes: [.font: smallFont, .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.55, alpha: 1)]
    )

    let visible = Array(lines.suffix(visibleLineCount))
    let lineHeight: CGFloat = 35
    var y: CGFloat = CGFloat(height - 120)
    for line in visible {
        let font = line.hasPrefix("$ ") || line.range(of: #"^[1-5]\. "#, options: .regularExpression) != nil
            ? terminalBold : terminalFont
        (line as NSString).draw(
            at: NSPoint(x: 52, y: y),
            withAttributes: [.font: font, .foregroundColor: lineColor(line)]
        )
        y -= lineHeight
    }

    let footer = "Recorded from a timestamped PTY session · no wallet key · no signing capability"
    (footer as NSString).draw(
        at: NSPoint(x: 52, y: 25),
        withAttributes: [.font: smallFont, .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1)]
    )
    NSGraphicsContext.restoreGraphicsState()
    return buffer
}

var renderedLines: [String] = []
var currentLine = ""
var eventIndex = 0

func appendTerminalText(_ text: String) {
    for character in text {
        if character == "\n" {
            renderedLines.append(contentsOf: wrappedLines(currentLine))
            currentLine = ""
        } else if character == "\u{0008}" {
            if !currentLine.isEmpty { currentLine.removeLast() }
        } else if character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            currentLine.append(character)
        }
    }
}

for frame in 0..<totalFrames {
    let elapsed = Double(frame) / Double(fps)
    let absoluteSecond = firstTimestamp + Int(elapsed.rounded(.down))
    while eventIndex < events.count && events[eventIndex].timestamp <= absoluteSecond {
        appendTerminalText(events[eventIndex].text)
        eventIndex += 1
    }
    var frameLines = renderedLines
    if !currentLine.isEmpty { frameLines.append(contentsOf: wrappedLines(currentLine)) }
    let buffer = drawFrame(lines: frameLines, elapsed: elapsed)
    while !writerInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    let presentationTime = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
    if !adaptor.append(buffer, withPresentationTime: presentationTime) {
        fail(writer.error?.localizedDescription ?? "failed to append frame")
    }
}

writerInput.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: CMTimeValue(totalFrames), timescale: CMTimeScale(fps)))
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()
guard writer.status == .completed else {
    fail(writer.error?.localizedDescription ?? "video writing failed")
}

print("rendered \(outputURL.path) (\(totalSeconds)s, \(width)x\(height), \(fps) fps)")
