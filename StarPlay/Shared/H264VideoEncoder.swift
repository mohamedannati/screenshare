import CoreMedia
import Foundation
import VideoToolbox

struct EncodedVideoFrame {
    let annexBData: Data
    let presentationTimeMicroseconds: Int64
    let isKeyFrame: Bool
    let width: Int
    let height: Int
}

struct H264ParameterSets {
    let sps: Data
    let pps: Data
}

/// Hardware-backed H.264 encoder for the memory-constrained broadcast extension.
final class H264VideoEncoder {
    private var compressionSession: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let profile: StreamProfile
    private let onConfiguration: (H264ParameterSets) -> Void
    private let onFrame: (EncodedVideoFrame) -> Void
    private let stateLock = NSLock()
    private var hasPublishedConfiguration = false
    private var forceNextKeyFrame = true

    init(
        width: Int,
        height: Int,
        profile: StreamProfile,
        onConfiguration: @escaping (H264ParameterSets) -> Void,
        onFrame: @escaping (EncodedVideoFrame) -> Void
    ) throws {
        self.width = width
        self.height = height
        self.profile = profile
        self.onConfiguration = onConfiguration
        self.onFrame = onFrame

        var session: VTCompressionSession?
        let encoderSpecification: CFDictionary?
        if #available(iOS 17.4, *) {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary
        } else {
            encoderSpecification = nil
        }
        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: H264VideoEncoder.compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw NSError(domain: "com.c0derz.starplay.encoder", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The hardware video encoder could not be created."
            ])
        }

        compressionSession = session
        setEncoderProperties(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        invalidate()
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }
        stateLock.lock()
        let shouldForceKeyFrame = forceNextKeyFrame
        forceNextKeyFrame = false
        stateLock.unlock()
        let frameProperties: CFDictionary? = shouldForceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            stateLock.lock()
            forceNextKeyFrame = true
            stateLock.unlock()
        }
    }

    func requestKeyFrame() {
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
    }

    func invalidate() {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
    }

    private func setEncoderProperties(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)

        let keyFrameInterval = NSNumber(value: profile.keyFrameInterval)
        let averageBitrate = NSNumber(value: profile.bitrate)
        let maxFrameIntervalDuration = NSNumber(value: 2.0)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: maxFrameIntervalDuration)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrate)

        let bytesPerSecond = max(1, profile.bitrate / 8)
        let dataRateLimits: CFArray = [bytesPerSecond * 2, 2] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        if !hasPublishedConfiguration, let sets = Self.parameterSets(from: formatDescription) {
            hasPublishedConfiguration = true
            onConfiguration(sets)
        }

        guard let annexBData = Self.annexBData(from: blockBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(pts)
        guard seconds.isFinite else { return }

        onFrame(EncodedVideoFrame(
            annexBData: annexBData,
            presentationTimeMicroseconds: Int64(seconds * 1_000_000),
            isKeyFrame: isKeyFrame,
            width: width,
            height: height
        ))
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard status == noErr, let refcon, let sampleBuffer else { return }
        let encoder = Unmanaged<H264VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleEncodedSampleBuffer(sampleBuffer)
    }

    private static func parameterSets(from formatDescription: CMFormatDescription) -> H264ParameterSets? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr, ppsStatus == noErr,
              let spsPointer, let ppsPointer,
              spsSize > 0, ppsSize > 0 else { return nil }
        return H264ParameterSets(
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func annexBData(from blockBuffer: CMBlockBuffer) -> Data? {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }
        var avccData = Data(count: totalLength)
        let status: OSStatus = avccData.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var output = Data()
        var offset = 0
        while offset + 4 <= avccData.count {
            let nalLength = Int(avccData.h264ReadUInt32(at: offset))
            offset += 4
            guard nalLength > 0, offset + nalLength <= avccData.count else { return nil }
            output.append(contentsOf: [UInt8(0), UInt8(0), UInt8(0), UInt8(1)])
            output.append(avccData[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return offset == avccData.count ? output : nil
    }
}

private extension Data {
    func h264ReadUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}
