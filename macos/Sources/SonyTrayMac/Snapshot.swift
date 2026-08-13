import AppKit
import SwiftUI

/// `SonyTray --snapshot <path>` — renders the flyout offscreen to a PNG.
///
/// A layout smoke test: the status item's popover can't be screenshotted from CI (or by an agent
/// working headlessly), and the band sliders in particular are rotated a quarter turn, which is
/// the kind of thing that silently breaks. Renders with a fresh, unstarted view model, so what
/// you get is the disconnected default state.
///
/// Caveat: `ImageRenderer` can't rasterise AppKit-backed controls, so sliders, pickers and the
/// checkbox come out as struck-through placeholder blocks. Their *footprints* are accurate, which
/// is the point — use this to check geometry, not to judge how the controls look.
enum Snapshot {
    @MainActor
    static func write(to path: String) -> Int32 {
        let session = HeadphonesSession() // deliberately not started — no Bluetooth access
        let viewModel = MainViewModel(session: session)
        // ImageRenderer rather than NSView.cacheDisplay: the latter misses SwiftUI's layer-backed
        // drawing and produces control chrome with no text.
        let renderer = ImageRenderer(content: FlyoutView(viewModel: viewModel).background(.white))
        renderer.scale = 2

        guard let image = renderer.nsImage, image.size.width > 0, image.size.height > 0 else {
            FileHandle.standardError.write(Data("snapshot: renderer produced no image\n".utf8))
            return 1
        }
        let size = image.size
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot: PNG encoding failed\n".utf8))
            return 1
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("wrote \(path) (\(Int(size.width))×\(Int(size.height)))")
        return 0
    }
}
