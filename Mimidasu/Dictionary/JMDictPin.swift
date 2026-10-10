import Foundation

/// The pinned JMDict_Extended input. One release, never floating: the app
/// ships dictionary data derived from exactly this asset, and
/// `scripts/build_dictionary.sh` asserts its own copy of these constants matches
/// before doing any work — a pin bump must touch both or nothing builds.
enum JMDictPin {
    /// Full upstream release tag — never the date alone.
    static let releaseTag = "1.4.1-auto-release-2026-09-01"

    /// Upstream release asset this pin points at.
    static let sourceAssetFileName = "jmdictExtended-2026-09-01.json.zip"

    /// SHA-256 of the zipped asset, cross-checked against the digest GitHub
    /// publishes on the release asset at build time.
    static let sourceSHA256 = "4bee23eb7bd088d0a9c48301d0d25964b8ac9ecd6465c91b40adf8191d4b040a"

    /// Local ingestion-recipe revision, appended to the artifact tag. The
    /// release tag above stays the upstream GitHub identifier (it keys the
    /// download URL in `build_dictionary.sh`); this revision is the artifact
    /// staleness key — bumped when the build mapping changes under the same
    /// upstream pin so prepared installs re-stage.
    static let buildRevision = "6"

    /// The character the build joins a sense's glosses with in the stored
    /// `senses.gloss` column, and the character every consumer splits that
    /// column back on. It is a control character that cannot occur inside an
    /// English gloss, which is the point: the historical joiner `"; "` occurs
    /// inside real glosses ("to scoop up (and remove; sand, earth, etc.)" is
    /// one gloss), and splitting on it shredded those glosses at every display
    /// site. The build tripwires a gloss that carries this character instead
    /// of storing it, and `scripts/build_dictionary.sh` pins both the Python
    /// and the Swift declaration against drift. Revision 6 is the first
    /// revision that stores it; earlier revisions joined with `"; "`.
    static let glossJoiner: Unicode.Scalar = "\u{001F}"

    /// Full upstream release tag of the pinned JMnedict names asset — never
    /// the date alone. The names source is scriptin/jmdict-simplified while
    /// the JMDict source above stays Bluskyo/JMDict_Extended; the two bump
    /// independently.
    static let nameReleaseTag = "3.6.2+20260914172325"

    /// Upstream release asset the names pin points at.
    static let nameSourceAssetFileName = "jmnedict-all-3.6.2+20260914172325.json.zip"

    /// SHA-256 of the zipped names asset, cross-checked against the digest
    /// GitHub publishes on the release asset at build time.
    static let nameSourceSHA256 = "843470cd19284d6caea54e6027df1791402766bd90ba70d36dba0cd787aeaa2a"

    /// Artifact-family naming. The versioned filename below is derived from
    /// it, and the store's stale-artifact sweep keys on the prefix/extension
    /// rather than the versioned name, so a pin bump keeps matching.
    static let artifactPrefix = "jmdict-"
    static let artifactExtension = "sqlite"

    /// Versioned artifact names derived from the tag and build revision. Tag
    /// + revision is the staleness key: an app update shipping a new pin, or
    /// a new ingestion recipe under the same pin, stages a new file and the
    /// stale one is simply inert.
    static let preparedFileName = "\(artifactPrefix)\(releaseTag).\(buildRevision).\(artifactExtension)"
    static let bundledFileName = preparedFileName + ".zst"

    /// The debug-checkout database, carrying the gloss index.
    ///
    /// The bundled `.zst` is the raw ingestion output and must stay that way —
    /// the index is derived at first launch into Application Support, so it
    /// costs the shipped bundle nothing. A debug checkout that resolved the
    /// *raw* database instead would run every Latin gloss search against a
    /// database with no index and no `LIKE` fallback, and fail silently.
    /// `scripts/build_dictionary.sh` emits this file alongside the raw one by
    /// applying the same DDL `JMDictFTSIndex` applies, and guards the two
    /// against drift.
    static let devArtifactFileName =
        "\(artifactPrefix)\(releaseTag).\(buildRevision).dev.\(artifactExtension)"

    /// The uncompressed, index-carrying intermediate `scripts/build_dictionary.sh`
    /// leaves in the checkout's `build/`; debug-only discovery path.
    static let debugCheckoutPath = "build/\(devArtifactFileName)"
}
