import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 5 else {
    fail("usage: swift render_video.swift OUTPUT.mp4 NARRATION.aiff FRAME1.png FRAME2.png ...")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])
let frameURLs = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
let fileManager = FileManager.default
let videoOnlyURL = outputURL.deletingPathExtension().appendingPathExtension("video-only.mp4")
try? fileManager.removeItem(at: outputURL)
try? fileManager.removeItem(at: videoOnlyURL)

let audioAsset = AVURLAsset(url: audioURL)
let audioDuration = audioAsset.duration
let totalSeconds = max(CMTimeGetSeconds(audioDuration) + 1.5, Double(frameURLs.count) * 4.0)
let totalDuration = CMTime(seconds: totalSeconds, preferredTimescale: 600)
let slideSeconds = totalSeconds / Double(frameURLs.count)

let width = 1920
let height = 1080
let fps = 2

guard let writer = try? AVAssetWriter(outputURL: videoOnlyURL, fileType: .mp4) else {
    fail("could not create video writer")
}

let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_800_000]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let attributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
guard writer.canAdd(input) else { fail("video writer rejected input") }
writer.add(input)
guard writer.startWriting() else { fail(writer.error?.localizedDescription ?? "video writer failed to start") }
writer.startSession(atSourceTime: .zero)

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("could not load \(url.path)")
    }
    return image
}

func makePixelBuffer(_ image: CGImage) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { fail("could not create pixel buffer") }
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
    ) else { fail("could not create bitmap context") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

for (slideIndex, frameURL) in frameURLs.enumerated() {
    let buffer = makePixelBuffer(loadImage(frameURL))
    let startFrame = Int((Double(slideIndex) * slideSeconds * Double(fps)).rounded())
    let endFrame = Int((Double(slideIndex + 1) * slideSeconds * Double(fps)).rounded())
    for frame in startFrame..<endFrame {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        let presentationTime = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        if !adaptor.append(buffer, withPresentationTime: presentationTime) {
            fail(writer.error?.localizedDescription ?? "failed to append frame")
        }
    }
}

input.markAsFinished()
writer.endSession(atSourceTime: totalDuration)
let writeSemaphore = DispatchSemaphore(value: 0)
writer.finishWriting { writeSemaphore.signal() }
writeSemaphore.wait()
guard writer.status == .completed else { fail(writer.error?.localizedDescription ?? "video writing failed") }

let composition = AVMutableComposition()
let videoAsset = AVURLAsset(url: videoOnlyURL)
guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
      let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    fail("could not load generated video track")
}
try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: totalDuration), of: sourceVideo, at: .zero)
targetVideo.preferredTransform = sourceVideo.preferredTransform

if let sourceAudio = audioAsset.tracks(withMediaType: .audio).first,
   let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
    try targetAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: sourceAudio, at: .zero)
}

guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
    fail("could not create video exporter")
}
exporter.outputURL = outputURL
exporter.outputFileType = .mp4
exporter.shouldOptimizeForNetworkUse = true
let exportSemaphore = DispatchSemaphore(value: 0)
exporter.exportAsynchronously { exportSemaphore.signal() }
exportSemaphore.wait()
try? fileManager.removeItem(at: videoOnlyURL)
guard exporter.status == .completed else { fail(exporter.error?.localizedDescription ?? "video export failed") }

print("rendered \(outputURL.path) (\(String(format: "%.1f", totalSeconds)) seconds)")
