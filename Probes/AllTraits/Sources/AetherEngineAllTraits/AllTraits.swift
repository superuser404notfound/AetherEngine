@_exported import AetherEngine

/// Every optional component this consumer enabled, as the engine reports them at run time.
public let enabledOptionalComponents = AetherEngine.OptionalComponent.allCases.filter(\.isBuiltIn)
