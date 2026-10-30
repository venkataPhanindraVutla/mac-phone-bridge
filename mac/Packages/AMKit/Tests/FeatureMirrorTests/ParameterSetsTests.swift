import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import FeatureMirror

@Suite struct ParameterSetsTests {
    @Test func splitAnnexBHandlesThreeAndFourByteStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5])
        #expect(ParameterSets.splitAnnexB(data) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])])
        // Trailing zero bytes belong to no NAL unit; an empty input has none.
        #expect(ParameterSets.splitAnnexB(Data([0, 0, 1, 0x09, 0xF0, 0, 0])) == [Data([0x09, 0xF0])])
        #expect(ParameterSets.splitAnnexB(Data()).isEmpty)
    }

    @Test func sampleSpsPpsBuildFormat() throws {
        let config = try #require(samplePackets.first)
        #expect(config.config)
        let format = try #require(ParameterSets.formatDescription(codec: .h264, nals: ParameterSets.splitAnnexB(config.payload)))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 320 && size.height == 640)
    }

    @Test func missingParameterSetsBuildNothing() throws {
        let config = try #require(samplePackets.first)
        let nals = ParameterSets.splitAnnexB(config.payload)
        #expect(ParameterSets.formatDescription(codec: .h264, nals: [nals[0]]) == nil)
        #expect(ParameterSets.formatDescription(codec: .h265, nals: nals) == nil)
        #expect(ParameterSets.formatDescription(codec: .opus, nals: nals) == nil)
    }

    @Test(.enabled(if: TestEncoder.available(kCMVideoCodecType_HEVC), "needs the HEVC encoder"))
    func hevcParameterSetsBuildFormat() throws {
        let packets = try #require(TestEncoder.encode(kCMVideoCodecType_HEVC, width: 320, height: 640, count: 1))
        let nals = ParameterSets.splitAnnexB(packets[0].payload)
        #expect(nals.map { ($0[0] >> 1) & 0x3F } == [32, 33, 34])
        let format = try #require(ParameterSets.formatDescription(codec: .h265, nals: nals))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 320 && size.height == 640)
    }
}
