import Foundation

/// What object audio is doing while `LoadOptions.objectAudioRendering` plays TrueHD Atmos or
/// DTS:X, published as `LiveTelemetry.objectAudio`: the bed the presentation is built into, how
/// many objects it declares, how many of them play and how many of those sit overhead.
///
/// The counts come from the object metadata, as the session log's `bed levels` line does: an active
/// object can still be silent. They are what
/// the engine was asked to place, which is what a host showing "Atmos with heights" can stand on.
public struct ObjectAudioActivity: Equatable, Sendable {
    /// The speaker bed the presentation is rendered into, `objectAudioRendering`'s layout.
    public let layout: SpatialSpeakerLayout
    /// Dynamic objects the presentation declares; its bed channels and LFE are not objects.
    public let objects: Int
    /// Objects with a gain above zero in the latest metadata update.
    public let activeObjects: Int
    /// Active objects above ear level.
    public let elevatedObjects: Int
    /// Bed channels on height speakers. DTS:X's standard presentation carries its four heights this
    /// way rather than as objects, so a DTS:X track can read 0 objects and still play overhead.
    public let heightChannels: Int

    public init(layout: SpatialSpeakerLayout, objects: Int, activeObjects: Int, elevatedObjects: Int, heightChannels: Int) {
        self.layout = layout
        self.objects = objects
        self.activeObjects = activeObjects
        self.elevatedObjects = elevatedObjects
        self.heightChannels = heightChannels
    }
}
