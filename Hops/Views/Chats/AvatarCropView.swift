import SwiftUI

/// Pinch-and-drag crop for avatar photos: position the image inside the circle,
/// Save renders exactly what's framed.
struct AvatarCropView: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let cropSize: CGFloat = 300

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    imageView
                        .frame(width: cropSize, height: cropSize)
                        .clipShape(Rectangle())
                    // Darken outside the circle so the final crop is obvious.
                    Circle()
                        .inverseMask()
                        .foregroundStyle(.black.opacity(0.55))
                        .frame(width: cropSize, height: cropSize)
                        .allowsHitTesting(false)
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: cropSize, height: cropSize)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture.simultaneously(with: magnifyGesture))
                Text("Pinch to zoom, drag to position")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle("Position Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onCrop(renderCrop())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var imageView: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(scale)
            .offset(offset)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(6, max(1, committedScale * value.magnification))
            }
            .onEnded { _ in committedScale = scale }
    }

    /// Reproduce the on-screen framing into a square bitmap.
    private func renderCrop() -> UIImage {
        let output: CGFloat = 512
        let factor = output / cropSize
        // scaledToFill base size inside the crop square.
        let imageSize = image.size
        let baseScale = cropSize / min(imageSize.width, imageSize.height)
        let drawSize = CGSize(width: imageSize.width * baseScale * scale * factor,
                              height: imageSize.height * baseScale * scale * factor)
        let origin = CGPoint(x: (output - drawSize.width) / 2 + offset.width * factor,
                             y: (output - drawSize.height) / 2 + offset.height * factor)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output))
        return renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

private extension Circle {
    /// Everything except the circle, for the darkened surround.
    func inverseMask() -> some View {
        Rectangle()
            .compositingGroup()
            .overlay(self.blendMode(.destinationOut))
            .compositingGroup()
    }
}
