import CoreAudio
import Foundation

/// Static construction and teardown of the Core Audio objects behind
/// `SystemAudioCapture`: a global process tap — the whole system mix, minus
/// excluded processes — attached as the sole input of a private aggregate
/// device. Excluded from unit tests: every call talks to the audio HAL.
enum ProcessTapSetup {

    /// A created tap: its HAL object ID plus the UID needed to attach it to
    /// an aggregate device.
    struct Tap {
        let id: AudioObjectID
        let uid: String
    }

    /// Creates a stereo global tap with playback left unmuted — audio is
    /// captured by the tap and still reaches the speakers.
    static func createTap(
        excluding excludedProcesses: [NSNumber]
    ) throws(CaptureError) -> Tap {
        // `initStereoGlobalTapButExcludeProcesses:` is public API — declared in
        // CoreAudio's CATapDescription.h. The leading `__` is only the Clang
        // importer's raw form for an `NS_REFINED_FOR_SWIFT` initializer, not
        // private SPI. Creating the tap cannot be refused by TCC, so a
        // non-zero status here is a setup failure, not a permission denial.
        let description = CATapDescription(
            __stereoGlobalTapButExcludeProcesses: excludedProcesses
        )
        description.name = "Mimi system audio tap"
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CaptureError.streamSetupFailed("AudioHardwareCreateProcessTap: \(status)")
        }
        do {
            let uid = try tapUID(of: tapID)
            return Tap(id: tapID, uid: uid)
        } catch {
            destroyTap(tapID)
            throw error
        }
    }

    static func destroyTap(_ id: AudioObjectID) {
        guard id != kAudioObjectUnknown else { return }
        AudioHardwareDestroyProcessTap(id)
    }

    /// Mimi's own HAL process object, for exclusion from the global tap.
    static func ownProcessObject() throws(CaptureError) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutableBytes(of: &pid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), qualifier.baseAddress,
                &size, &processID
            )
        }
        guard status == noErr, processID != kAudioObjectUnknown else {
            throw CaptureError.streamSetupFailed("own process lookup: \(status)")
        }
        return processID
    }

    /// The tap's `CFString` UID, needed to attach it to an aggregate device.
    private static func tapUID(of tapID: AudioObjectID) throws(CaptureError) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { uidPtr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, uidPtr)
        }
        guard status == noErr, let ref = uidRef else {
            throw CaptureError.streamSetupFailed("tap UID: \(status)")
        }
        // kAudioTapPropertyUID returns a CFString the caller owns (+1), so
        // `takeRetainedValue` is the balanced release.
        return ref.takeRetainedValue() as String
    }

    /// The tap's stream format — the system mix's native ASBD.
    static func format(of tapID: AudioObjectID) throws(CaptureError) -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID, &address, 0, nil, &size, &asbd
        )
        guard status == noErr else {
            throw CaptureError.streamSetupFailed("tap format: \(status)")
        }
        return asbd
    }

    /// Private aggregate device with the tap as its only input; IO never
    /// reaches other apps, and `tapautostart` runs IO whenever the tapped
    /// mix produces audio.
    static func createAggregateDevice(tapUID: String) throws(CaptureError) -> AudioDeviceID {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimi System Audio Capture",
            kAudioAggregateDeviceUIDKey: "mimi.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
        ]
        var deviceID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            throw CaptureError.streamSetupFailed("AudioHardwareCreateAggregateDevice: \(status)")
        }
        return deviceID
    }
}
