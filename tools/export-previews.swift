// Renders the Welcome screen's animated feature cards to PNG frames.
// The frames are assembled into the README GIFs by tools/export-previews.sh.
//
// Usage: export-previews <output-directory> [--kind <name|all>]
//                        [--appearance light|dark] [--scale 2]
//                        [--fps 20] [--width 254] [--height 270]
import AppKit
import SwiftUI

@main
struct ExportPreviews {
    private struct Kind {
        let name: String
        let preview: FeaturePreviewKind
        let duration: TimeInterval
    }

    private static let kinds: [Kind] = [
        Kind(name: "three-finger-tap", preview: .threeFingerTap, duration: FeatureAnimationClock.loop / 2),
        Kind(name: "quit-dock-app", preview: .quitDockApp, duration: FeatureAnimationClock.loop),
        Kind(name: "multi-action", preview: .multiAction, duration: FeatureAnimationClock.loop)
    ]

    @MainActor
    static func main() {
        var output = "build/preview-frames"
        var requestedKind = "all"
        var appearanceName = "light"
        var scale: CGFloat = 2
        var fps = 20
        var width: CGFloat = 254
        var height: CGFloat = 270

        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        if let first = arguments.first, !first.hasPrefix("--") {
            output = first
            index = 1
        }
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                fail("Missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--kind": requestedKind = value
            case "--appearance": appearanceName = value
            case "--scale": scale = CGFloat(Double(value) ?? 2)
            case "--fps": fps = Int(value) ?? 20
            case "--width": width = CGFloat(Double(value) ?? 254)
            case "--height": height = CGFloat(Double(value) ?? 270)
            default: fail("Unknown option \(flag)")
            }
            index += 2
        }

        guard appearanceName == "light" || appearanceName == "dark" else {
            fail("--appearance must be light or dark")
        }
        guard fps > 0, scale > 0, width > 0, height > 0 else {
            fail("--fps, --scale, --width, and --height must be positive")
        }

        let selected = requestedKind == "all"
            ? kinds
            : kinds.filter { $0.name == requestedKind }
        guard !selected.isEmpty else {
            fail("--kind must be all or one of: \(kinds.map(\.name).joined(separator: ", "))")
        }

        // AppKit has to exist before SwiftUI resolves semantic colors and fonts.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)
        let colorScheme: ColorScheme = appearanceName == "dark" ? .dark : .light

        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        for kind in selected {
            let kindURL = outputURL.appendingPathComponent(kind.name, isDirectory: true)
            try? FileManager.default.removeItem(at: kindURL)
            do {
                try FileManager.default.createDirectory(at: kindURL, withIntermediateDirectories: true)
            } catch {
                fail("Could not create \(kindURL.path): \(error.localizedDescription)")
            }

            let frameCount = Int((kind.duration * Double(fps)).rounded())
            for frame in 0..<frameCount {
                let time = Double(frame) / Double(fps)
                let date = Date(timeIntervalSinceReferenceDate: time)
                let card = FeaturePreviewCard(kind: kind.preview, date: date)
                    .frame(width: width, height: height)
                    .environment(\.colorScheme, colorScheme)

                let renderer = ImageRenderer(content: card)
                renderer.scale = scale
                renderer.proposedSize = ProposedViewSize(width: width, height: height)
                renderer.isOpaque = false

                guard let cgImage = renderer.cgImage else {
                    fail("ImageRenderer produced no image for \(kind.name) frame \(frame)")
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    fail("Could not encode \(kind.name) frame \(frame)")
                }
                let file = kindURL.appendingPathComponent(String(format: "frame-%04d.png", frame))
                do {
                    try data.write(to: file)
                } catch {
                    fail("Could not write \(file.path): \(error.localizedDescription)")
                }
            }
            print("Rendered \(frameCount) frames for \(kind.name) to \(kindURL.path)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("export-previews: \(message)\n", stderr)
        exit(1)
    }
}
