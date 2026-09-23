// AmgiApp/Sources/Widgets/AmgiWidgetBundle.swift
import WidgetKit
import SwiftUI
import WidgetFeature
import AppIntents

struct IjukaWidgetExtensionIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [IjukaWidgetIntentsPackage.self]
    }
}

@main
struct AmgiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AmgiWidget()
    }
}
