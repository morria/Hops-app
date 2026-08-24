import UIKit

extension UIImage {
    /// Downscale a picked photo to avatar size and compress — small enough to
    /// live in the store and sync via CloudKit without ceremony.
    func scaledForAvatar(maxDimension: CGFloat = 256) -> Data? {
        let largest = max(size.width, size.height)
        let scale = min(1, maxDimension / max(largest, 1))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
