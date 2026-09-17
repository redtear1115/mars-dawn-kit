#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation

/// Writes an H.264 `.mp4` of noise frames, large enough that its media data spans more than
/// one 8 MB range. Noise doesn't compress, so the encoder spends its whole bit rate.
///
/// The movie header (`moov`) goes after the media data, so a player must reach the end of the
/// file, well past the first 8 MB, before it knows the duration or the frame size.
enum HTMLMediaFixture {
    enum Failure: Error { case setup, writing(Error?), tooSmall(Int) }

    /// Offsets of the top-level boxes, by type.
    static func topLevelBoxes(in data: Data) -> [(type: String, offset: Int)] {
        var boxes: [(String, Int)] = []
        var offset = 0
        while offset + 8 <= data.count {
            var size = data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if size == 1, offset + 16 <= data.count {
                size = data[(offset + 8)..<(offset + 16)].reduce(0) { $0 << 8 | Int($1) }
            } else if size == 0 {
                size = data.count - offset
            }
            boxes.append((type, offset))
            guard size >= 8 else { break }
            offset += size
        }
        return boxes
    }

    static func writeNoiseMovie(to url: URL, minimumBytes: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 1280, height = 720, frames = 300
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.setup }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writing(writer.error) }
        writer.startSession(atSourceTime: .zero)

        var frame = 0
        while frame < frames {
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.setup }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.setup }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                arc4random_buf(base, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw Failure.writing(writer.error)
            }
            frame += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writing(writer.error) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size >= minimumBytes else { throw Failure.tooSmall(size) }
    }
}
#endif
