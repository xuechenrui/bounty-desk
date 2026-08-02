import AppKit
import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 4 else {
    fail("usage: swift extract_video_frames.swift VIDEO OUTPUT_DIR SECOND...")
}

let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let asset = AVURLAsset(url: videoURL)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

for rawSecond in CommandLine.arguments.dropFirst(3) {
    guard let second = Double(rawSecond), second >= 0 else {
        fail("invalid timestamp: \(rawSecond)")
    }
    let requestedTime = CMTime(seconds: second, preferredTimescale: 600)
    let semaphore = DispatchSemaphore(value: 0)
    var extractedImage: CGImage?
    var actualTime = CMTime.zero
    var extractionError: Error?
    generator.generateCGImageAsynchronously(for: requestedTime) { image, generatedTime, error in
        extractedImage = image
        actualTime = generatedTime
        extractionError = error
        semaphore.signal()
    }
    semaphore.wait()
    guard let image = extractedImage else {
        fail("could not extract frame at \(rawSecond)s: \(extractionError?.localizedDescription ?? "unknown error")")
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        fail("could not encode frame at \(rawSecond)s")
    }
    let label = String(format: "%05.1f", second).replacingOccurrences(of: ".", with: "-")
    let outputURL = outputDirectory.appendingPathComponent("frame-\(label)s.png")
    do {
        try png.write(to: outputURL)
    } catch {
        fail("could not save \(outputURL.path): \(error)")
    }
    print("\(rawSecond)s -> \(outputURL.path) (actual \(CMTimeGetSeconds(actualTime))s)")
}
