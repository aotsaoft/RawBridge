import Foundation

enum ImportSource: String, CaseIterable, Identifiable {
    case files = "THẺ NHỚ / FILES"
    case photos = "CAMERA ROLL"

    var id: String { rawValue }
}
