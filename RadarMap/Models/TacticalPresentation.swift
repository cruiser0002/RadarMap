import Foundation

/// Defines the top-level tactical visualization presentation.
public enum TacticalPresentation: String, CaseIterable, Identifiable, Codable {
    case map = "Map"
    case radar = "Radar"
    
    public var id: String { rawValue }
}
