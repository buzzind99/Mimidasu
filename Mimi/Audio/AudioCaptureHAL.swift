import CoreAudio
import Foundation
import Synchronization

/// Owns the Core Audio objects behind `SystemAudioCapture` — the process tap,
/// the private aggregate device, the IO proc, and their property listeners —
/// plus the tap's live stream format. The IDs are claimed as a unit by exactly
/// one teardown path, so `stop()`, `deinit`, and the dead-device listener can
/// race freely without leaking or double-destroying. Split from
/// `SystemAudioCapture` to keep that class on the data path (and under the
/// lint gate).
final class AudioCaptureHAL: @unchecked Sendable {

    private struct HALHandles {
        var tapID: AudioObjectID?
        var aggregateID: AudioDeviceID?
        var ioProcID: AudioDeviceIOProcID?
        var deviceDiedListener: PropertyListener?
        var tapListListener: PropertyListener?
        var formatListener: PropertyListener?
    }

    /// The live HAL handles; empty whenever no capture is up.
    private let live = Mutex(HALHandles())

    /// The tap's stream format. A `Mutex`, not a plain field: the IO block
    /// reads it on the capture's IO queue while the format-change listener
    /// rewrites it on the listener queue when the output device (and its
    /// rate) changes.
    private let tapFormat = Mutex<AudioStreamBasicDescription?>(nil)

    var currentTapFormat: AudioStreamBasicDescription? {
        tapFormat.withLock { value in value }
    }

    // MARK: - Ownership

    func trackTap(_ id: AudioObjectID) {
        live.withLock { current in current.tapID = id }
    }

    func trackAggregate(_ id: AudioDeviceID) {
        live.withLock { current in current.aggregateID = id }
    }

    func trackIOProc(_ id: AudioDeviceIOProcID) {
        live.withLock { current in current.ioProcID = id }
    }

    func storeTapFormat(_ asbd: AudioStreamBasicDescription) {
        tapFormat.withLock { value in value = asbd }
    }

    // MARK: - Listeners

    /// Registers the three property listeners: aggregate death, tap-list
    /// change (a revoked tap can leave a live aggregate quietly delivering
    /// silence), and tap-format change. `onDeviceDied` fires on `queue`.
    func registerListeners(
        aggregate: AudioDeviceID,
        tap: AudioObjectID,
        queue: DispatchQueue,
        onDeviceDied: @escaping @Sendable (NSError) -> Void
    ) {
        let alive = makeListener(
            for: aggregate, selector: kAudioDevicePropertyDeviceIsAlive, queue: queue
        ) { onDeviceDied(Self.deviceDiedError("system audio capture device died")) }
        live.withLock { current in current.deviceDiedListener = alive }

        let tapList = makeListener(
            for: aggregate, selector: kAudioAggregateDevicePropertyTapList, queue: queue
        ) { onDeviceDied(Self.deviceDiedError("system audio capture tap list changed")) }
        live.withLock { current in current.tapListListener = tapList }

        registerFormatListener(tap: tap, queue: queue)
    }

    private func makeListener(
        for object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        onFire: @escaping @Sendable () -> Void
    ) -> PropertyListener {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onFire() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        checkListenerStatus(status, selector: selector)
        return PropertyListener(address: address, block: block)
    }

    /// A failed listener registration silently disables recovery (dead-device,
    /// tap-list, format-change) with no other symptom — surface it in DEBUG.
    private func checkListenerStatus(
        _ status: OSStatus, selector: AudioObjectPropertySelector
    ) {
        guard status != noErr else { return }
        #if DEBUG
            print("[capture] property listener '\(selector)' registration failed: \(status)")
        #endif
        assertionFailure("AudioObjectAddPropertyListenerBlock failed for '\(selector)': \(status)")
    }

    private func registerFormatListener(tap: AudioObjectID, queue: DispatchQueue) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let asbd = try? ProcessTapFactory.tapFormat(of: tap) else { return }
            tapFormat.withLock { value in value = asbd }
        }
        let status = AudioObjectAddPropertyListenerBlock(tap, &address, queue, block)
        checkListenerStatus(status, selector: kAudioTapPropertyFormat)
        live.withLock { current in
            current.formatListener = PropertyListener(address: address, block: block)
        }
    }

    private static func deviceDiedError(_ description: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioHardwareBadDeviceError),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    // MARK: - Teardown

    /// Synchronous teardown for callers already off their critical thread
    /// (the listener queue) and for `start()`'s failure arms.
    func teardownBlocking(on queue: DispatchQueue) {
        guard let claimed = claimLiveObjects() else { return }
        tapFormat.withLock { value in value = nil }
        removeListeners(claimed, queue: queue)
        Self.destroy(
            tap: claimed.tapID, aggregate: claimed.aggregateID, ioProc: claimed.ioProcID
        )
    }

    /// `stop()`'s and `deinit`'s path: claim synchronously, then destroy off
    /// the caller thread because `AudioDeviceStop` can block an IO period.
    /// Listener removal is immediate (cheap, and must match the registration
    /// queue); only the Sendable HAL object IDs cross into the detached task.
    func teardownDetached(on queue: DispatchQueue) {
        guard let claimed = claimLiveObjects() else { return }
        tapFormat.withLock { value in value = nil }
        removeListeners(claimed, queue: queue)
        let tap = claimed.tapID
        let aggregate = claimed.aggregateID
        let ioProc = claimed.ioProcID
        Task.detached(priority: .userInitiated) {
            Self.destroy(tap: tap, aggregate: aggregate, ioProc: ioProc)
        }
    }

    /// Atomically takes ownership of the live objects, emptying the stored
    /// slot so no second teardown path can double-destroy them. Nil when
    /// there is nothing left to tear down.
    private func claimLiveObjects() -> HALHandles? {
        live.withLock { current -> HALHandles? in
            guard current.tapID != nil || current.aggregateID != nil
                || current.ioProcID != nil
            else { return nil }
            let claimed = current
            current = HALHandles()
            return claimed
        }
    }

    private func removeListeners(_ claimed: HALHandles, queue: DispatchQueue) {
        if let device = claimed.aggregateID {
            if let listener = claimed.deviceDiedListener {
                Self.removeListener(listener, from: device, queue: queue)
            }
            if let listener = claimed.tapListListener {
                Self.removeListener(listener, from: device, queue: queue)
            }
        }
        if let tap = claimed.tapID, let listener = claimed.formatListener {
            Self.removeListener(listener, from: tap, queue: queue)
        }
    }

    private static func removeListener(
        _ listener: PropertyListener, from object: AudioObjectID, queue: DispatchQueue
    ) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener.block)
    }

    /// Static so teardown never needs `self`; `AudioDeviceStop` drains
    /// in-flight IO blocks before returning, so the caller may be any thread.
    private static func destroy(
        tap: AudioObjectID?, aggregate: AudioDeviceID?, ioProc: AudioDeviceIOProcID?
    ) {
        if let device = aggregate {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if let tap {
            ProcessTapFactory.destroyTap(tap)
        }
    }
}

/// A registered `AudioObjectPropertyListenerBlock` plus the address it was
/// registered under — both needed for the matching removal call. `@unchecked`
/// Sendable: it never actually crosses isolation unsafely (it only lives
/// inside `AudioCaptureHAL`'s mutex and is handed straight back to the HAL
/// removal call on the queue it was registered with), but the block typedef
/// isn't imported as `Sendable`.
private struct PropertyListener: @unchecked Sendable {
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}
