import AVFoundation
import SwiftUI
import UIKit

/// Displays a capture session owned, authorized, configured, and started by the host app.
/// This view never requests permission, changes inputs, or starts or stops capture.
@MainActor
public struct ODCameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera preview"
        return view
    }

    public func updateUIView(_ uiView: PreviewSurface, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    public static func dismantleUIView(_ uiView: PreviewSurface, coordinator: ()) {
        // Detach this presentation layer without affecting the host's running session.
        uiView.previewLayer.session = nil
    }

    public final class PreviewSurface: UIView {
        public override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        public var previewLayer: AVCaptureVideoPreviewLayer {
            // UIView creates the layer declared by layerClass above.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
