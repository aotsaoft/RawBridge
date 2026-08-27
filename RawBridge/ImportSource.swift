import Foundation

enum ImportSource: String, CaseIterable, Identifiable {
    case files = "THẺ NHỚ / FILES"
    case photos = "ẢNH CHỤP / CAMERA ROLL"

    var id: String { rawValue }
}
