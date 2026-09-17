import CoreAudio
import Foundation
@testable import Mimidasu
import Testing

/// Exercises `AudioCaptureHAL`'s pure state — tap-format storage and handle
/// tracking — with no Core Audio objects involved. Teardown and destroy paths
/// stay excluded: they call real HAL APIs.
@Suite("AudioCaptureHAL")
struct AudioCaptureHALTests {

    @Test("a fresh HAL has no stored tap format")
    func freshHasNoTapFormat() {
        let hal = AudioCaptureHAL()

        #expect(hal.currentTapFormat == nil)
    }

    @Test("a stored tap format round-trips through the getter")
    func storedTapFormatRoundTrips() throws {
        let hal = AudioCaptureHAL()
        let asbd = Self.makeASBD(sampleRate: 48000)

        hal.storeTapFormat(asbd)

        let stored = try #require(hal.currentTapFormat)
        #expect(stored.mSampleRate == 48000)
    }

    @Test("tracking HAL handles does not trap")
    func tracksHandlesWithoutTrapping() {
        let hal = AudioCaptureHAL()

        hal.trackTap(1)
        hal.trackAggregate(2)
        hal.trackIOProc(fakeIOProc)
    }

    @Test("device-died errors carry the bad-device HAL code and the listener reason")
    func deviceDiedErrorShape() {
        let error = AudioCaptureHAL.deviceDiedError("system audio capture device died")

        #expect(error.domain == NSOSStatusErrorDomain)
        #expect(error.code == Int(kAudioHardwareBadDeviceError))
        #expect(error.localizedDescription == "system audio capture device died")
    }

    private static func makeASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

private let fakeIOProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
