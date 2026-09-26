import Foundation

extension AetherEngine {

    /// The engine release this source descends from, in the form a host prints it.
    ///
    /// A host cannot work this out for itself. SwiftPM resolves a package to a revision, so a
    /// diagnostic log or an About panel that wants to name the engine has nothing to read but this.
    /// It is rewritten in the release prep commit alongside the README install snippets and the
    /// CHANGELOG entry, and `DocumentedConstantsTests` holds all four in step.
    ///
    /// Between releases, and in a consumer that pins an unreleased commit for a device test, this
    /// names the last PUBLISHED version the checkout descends from, not every patch in it.
    public nonisolated static let version = "7.18.1"
}
