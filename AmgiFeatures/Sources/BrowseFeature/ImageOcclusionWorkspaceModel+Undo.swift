import AmgiTheme
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Undo

extension ImageOcclusionWorkspaceModel {
    func currentSnapshot() -> IOMaskSnapshot {
        IOMaskSnapshot(
            masks: masks,
            selectedMaskIndex: selectedMaskIndex,
            selectedMaskIndices: Set(activeSelectionIndices)
        )
    }

    func commitSnapshot(_ snapshot: IOMaskSnapshot) {
        let previous = currentSnapshot()
        applySnapshot(snapshot)
        registerUndo(previous: previous, current: snapshot)
    }

    func registerUndo(previous: IOMaskSnapshot, current: IOMaskSnapshot) {
        // The model is the undo target now that this is a class, so the
        // registered blocks die with it. UndoManager invokes them on the
        // thread that registered them, which is always the main actor here.
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreSnapshot(previous, redo: current)
            }
        }
    }

    func restoreSnapshot(_ snapshot: IOMaskSnapshot, redo: IOMaskSnapshot) {
        applySnapshot(snapshot)
        registerUndo(previous: redo, current: snapshot)
    }

    func applySnapshot(_ snapshot: IOMaskSnapshot) {
        masks = snapshot.masks
        selectedMaskIndices = snapshot.selectedMaskIndices.filter { snapshot.masks.indices.contains($0) }
        if let selectedMaskIndex = snapshot.selectedMaskIndex, snapshot.masks.indices.contains(selectedMaskIndex) {
            self.selectedMaskIndex = selectedMaskIndex
        } else {
            self.selectedMaskIndex = selectedMaskIndices.sorted().first
        }
        occlusionMode = snapshot.masks.contains(where: \.occludesInactive) ? .hideAllGuessOne : .hideOneGuessOne
    }
}

// MARK: - Geometry and colour helpers

extension ImageOcclusionWorkspaceModel {
    func groupedSelectionIndices(for index: Int, in masks: [IOMask]? = nil) -> Set<Int> {
        let resolvedMasks = masks ?? self.masks
        guard resolvedMasks.indices.contains(index) else { return [] }
        guard let ordinal = resolvedMasks[index].serializationOrdinal else {
            return [index]
        }
        return Set(resolvedMasks.indices.filter { resolvedMasks[$0].serializationOrdinal == ordinal })
    }

    func nextAvailableOrdinal(in masks: [IOMask], reserved: Set<Int> = []) -> Int {
        let currentMax = masks.compactMap(\.serializationOrdinal).max() ?? 0
        var candidate = currentMax + 1
        while reserved.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    func color(from hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard let value = UInt64(trimmed, radix: 16) else { return fallback }
        let r, g, b, a: Double
        switch trimmed.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return fallback
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    func hexString(for color: Color) -> String {
        #if canImport(UIKit)
        UIColor(color).amgiHexString(includeAlpha: true)
        #elseif canImport(AppKit)
        NSColor(color).usingColorSpace(.sRGB).map { ns in
            func channel(_ value: CGFloat) -> Int { min(255, max(0, Int((value * 255).rounded()))) }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            ns.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%02X%02X%02X%02X", channel(r), channel(g), channel(b), channel(a))
        } ?? "000000FF"
        #else
        "000000FF"
        #endif
    }

    func normalizedBounds(for mask: IOMask) -> CGRect {
        switch mask {
        case .rect(let left, let top, let width, let height, _):
            return CGRect(x: left, y: top, width: width, height: height)
        case .ellipse(let left, let top, let rx, let ry, _):
            return CGRect(x: left, y: top, width: rx * 2, height: ry * 2)
        case .polygon(let points, _):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
        case .text(let left, let top, let text, let scale, let fontSize, _):
            return CGRect(origin: CGPoint(x: left, y: top), size: normalizedTextSize(text: text, scale: scale, fontSize: fontSize))
        }
    }

    func normalizedTextSize(text: String, scale: CGFloat, fontSize: CGFloat) -> CGSize {
        let resolvedSize = max(14, image.size.height * max(fontSize, 0.02) * max(scale, 1))
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: resolvedSize, weight: .semibold)
        #else
        let font = NSFont.systemFont(ofSize: resolvedSize, weight: .semibold)
        #endif
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        return CGSize(
            width: min(1, (textSize.width + 20) / max(image.size.width, 1)),
            height: min(1, (textSize.height + 12) / max(image.size.height, 1))
        )
    }

    func offset(mask: IOMask, dx: CGFloat, dy: CGFloat) -> IOMask {
        switch mask {
        case .rect(let left, let top, let width, let height, let extras):
            return .rect(
                left: max(0, min(1 - width, left + dx)),
                top: max(0, min(1 - height, top + dy)),
                width: width,
                height: height,
                extras: extras
            )
        case .ellipse(let left, let top, let rx, let ry, let extras):
            return .ellipse(
                left: max(0, min(1 - rx * 2, left + dx)),
                top: max(0, min(1 - ry * 2, top + dy)),
                rx: rx,
                ry: ry,
                extras: extras
            )
        case .polygon(let points, let extras):
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 1
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 1
            let clampedDX = max(-minX, min(1 - maxX, dx))
            let clampedDY = max(-minY, min(1 - maxY, dy))
            let shifted = points.map {
                CGPoint(x: $0.x + clampedDX, y: $0.y + clampedDY)
            }
            return .polygon(points: shifted, extras: extras)
        case .text(let left, let top, let text, let scale, let fontSize, let extras):
            let size = normalizedTextSize(text: text, scale: scale, fontSize: fontSize)
            return .text(
                left: max(0, min(1 - size.width, left + dx)),
                top: max(0, min(1 - size.height, top + dy)),
                text: text,
                scale: scale,
                fontSize: fontSize,
                extras: extras
            )
        }
    }
}
