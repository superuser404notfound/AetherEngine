import Testing

/// The Dolby Vision suites whose cases are long GPU and CPU loops: the dual-layer decoder, seek,
/// classification and GPU-slot suites, the real-clip suite and the two fuzz suites.
/// Run beside each other and beside the rest of the run they starve one another. They used to carry
/// the one-lane trait, so every case queued for the single lane behind the long real-clip decodes,
/// and the time a case waits for the lane counts against its `.timeLimit`: a full run in the default
/// parallel mode reported time-limit issues that were no real failure (every case passes one at a time).
/// `.serialized` here is recursive: the suites nested in it run one after another, so the lane
/// is no longer needed to keep them to one core, and a case that is waiting for its turn has not
/// started, so its `.timeLimit` has not either.
@Suite(.serialized)
enum HeavyDualLayerSuites {}

/// Other suites reach into these three for fixtures and helpers; the aliases keep those call sites
/// as they were.
typealias DoviFelFuzzTests = HeavyDualLayerSuites.DoviFelFuzzTests
typealias DoviCrcValidFuzzTests = HeavyDualLayerSuites.DoviCrcValidFuzzTests
typealias DoviFelRealFileTests = HeavyDualLayerSuites.DoviFelRealFileTests
