import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

enum RemoteHEVCDecoderError: LocalizedError {
    case missingParameterSets
    case malformedAccessUnit
    case mediaFailure(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingParameterSets:
            return "The remote video stream has not supplied its HEVC configuration yet."
        case .malformedAccessUnit:
            return "The remote device sent an invalid HEVC video frame."
        case .mediaFailure(let operation, let status):
            return "HEVC \(operation) failed (\(status))."
        }
    }
}

/// Low-latency VideoToolbox decoder for marker-closed Annex-B access units.
/// Instances are confined to the remote video queue; decoded images are copied
/// before being delivered to the main thread.
final class RemoteHEVCDecoder {
    private var videoParameterSet: Data?
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var activeConfiguration: [Data] = []
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var presentationValue: Int64 = 0

    func decode(
        annexB accessUnit: Data,
        timestamp: UInt32,
        completion: @escaping @Sendable (Result<UIImage, Error>) -> Void
    ) throws {
        let units = try Self.nalUnits(in: accessUnit)
        guard !units.isEmpty else { throw RemoteHEVCDecoderError.malformedAccessUnit }

        var sampleUnits: [Data] = []
        var isSync = false
        for unit in units {
            guard unit.count >= 2 else { continue }
            let type = (unit[unit.startIndex] >> 1) & 0x3f
            switch type {
            case 32: videoParameterSet = unit
            case 33: sequenceParameterSet = unit
            case 34: pictureParameterSet = unit
            case 35: continue // access-unit delimiter
            default:
                if type <= 31 { sampleUnits.append(unit) }
                if (16 ... 23).contains(type) { isSync = true }
            }
        }

        guard !sampleUnits.isEmpty else { return }
        try ensureDecoder()
        guard let session, let formatDescription else {
            throw RemoteHEVCDecoderError.missingParameterSets
        }

        var sampleData = Data()
        sampleData.reserveCapacity(sampleUnits.reduce(0) { $0 + $1.count + 4 })
        for unit in sampleUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(unit)
        }

        let sampleBuffer = try Self.makeSampleBuffer(
            bytes: sampleData,
            formatDescription: formatDescription,
            presentationValue: presentationValue,
            isSync: isSync
        )
        presentationValue &+= 1

        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 1),
            infoFlagsOut: &flags
        ) { status, infoFlags, imageBuffer, _, _, _ in
            guard status == noErr, !infoFlags.contains(.frameDropped), let imageBuffer else {
                completion(.failure(RemoteHEVCDecoderError.mediaFailure("decode", status)))
                return
            }
            var image: CGImage?
            let imageStatus = VTCreateCGImageFromCVPixelBuffer(
                imageBuffer,
                options: nil,
                imageOut: &image
            )
            guard imageStatus == noErr, let image else {
                completion(.failure(RemoteHEVCDecoderError.mediaFailure("image conversion", imageStatus)))
                return
            }
            completion(.success(UIImage(cgImage: image)))
        }
        guard status == noErr else {
            throw RemoteHEVCDecoderError.mediaFailure("submission", status)
        }
    }

    func stop() {
        guard let session else { return }
        _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        formatDescription = nil
    }

    deinit {
        stop()
    }

    private func ensureDecoder() throws {
        guard
            let videoParameterSet,
            let sequenceParameterSet,
            let pictureParameterSet
        else {
            throw RemoteHEVCDecoderError.missingParameterSets
        }
        let configuration = [videoParameterSet, sequenceParameterSet, pictureParameterSet]
        guard configuration != activeConfiguration || session == nil else { return }

        stop()
        var description: CMFormatDescription?
        let status = videoParameterSet.withUnsafeBytes { video in
            sequenceParameterSet.withUnsafeBytes { sequence in
                pictureParameterSet.withUnsafeBytes { picture in
                    guard
                        let videoBase = video.bindMemory(to: UInt8.self).baseAddress,
                        let sequenceBase = sequence.bindMemory(to: UInt8.self).baseAddress,
                        let pictureBase = picture.bindMemory(to: UInt8.self).baseAddress
                    else { return OSStatus(kCMFormatDescriptionError_InvalidParameter) }
                    let pointers = [videoBase, sequenceBase, pictureBase]
                    let sizes = configuration.map(\.count)
                    return pointers.withUnsafeBufferPointer { pointers in
                        sizes.withUnsafeBufferPointer { sizes in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointers.baseAddress!,
                                parameterSetSizes: sizes.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &description
                            )
                        }
                    }
                }
            }
        }
        guard status == noErr, let description else {
            throw RemoteHEVCDecoderError.mediaFailure("configuration", status)
        }

        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        var decoder: VTDecompressionSession?
        let decoderStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            decompressionSessionOut: &decoder
        )
        guard decoderStatus == noErr, let decoder else {
            throw RemoteHEVCDecoderError.mediaFailure("decoder creation", decoderStatus)
        }
        let realTimeStatus = VTSessionSetProperty(
            decoder,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard realTimeStatus == noErr else {
            VTDecompressionSessionInvalidate(decoder)
            throw RemoteHEVCDecoderError.mediaFailure("real-time configuration", realTimeStatus)
        }

        activeConfiguration = configuration
        formatDescription = description
        session = decoder
    }

    private static func makeSampleBuffer(
        bytes: Data,
        formatDescription: CMVideoFormatDescription,
        presentationValue: Int64,
        isSync: Bool
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw RemoteHEVCDecoderError.mediaFailure("buffer allocation", status)
        }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: $0.count
            )
        }
        guard status == noErr else {
            throw RemoteHEVCDecoderError.mediaFailure("buffer copy", status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationValue, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw RemoteHEVCDecoderError.mediaFailure("sample creation", status)
        }
        if !isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sample,
               createIfNecessary: true
           ) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = true
        }
        return sample
    }

    private static func nalUnits(in data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { throw RemoteHEVCDecoderError.malformedAccessUnit }
        return starts.enumerated().compactMap { position, start in
            let lower = start.offset + start.length
            let upper = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard upper > lower else { return nil }
            return Data(bytes[lower ..< upper])
        }
    }
}
