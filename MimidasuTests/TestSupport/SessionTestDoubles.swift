import Foundation
@testable import Mimidasu

/// Thread-safe ordered call log for the session doubles: records names from
/// the main actor and detached work alike.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ name: String) {
        lock.withLock { entries.append(name) }
    }

    var names: [String] {
        lock.withLock { entries }
    }

    /// True when `needle` appears as a subsequence of the recorded names.
    func contains(inOrder needle: [String]) -> Bool {
        var index = 0
        for entry in names where index < needle.count {
            if entry == needle[index] {
                index += 1
            }
        }
        return index == needle.count
    }
}

/// Thread-safe collector for sentences emitted by a controller.
final class SentenceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sentences: [Sentence] = []

    func record(_ sentence: Sentence) {
        lock.withLock { sentences.append(sentence) }
    }

    var all: [Sentence] {
        lock.withLock { sentences }
    }
}
