import CoreGraphics
import Foundation
@testable import BlipCore

func makeTarget(
    _ label: String,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 50,
    height: CGFloat = 20,
    source: TargetSource = .accessibility,
    windowID: CGWindowID? = nil,
    zIndex: Int = 0,
    appName: String = "TestApp"
) -> Target {
    Target(
        frame: CGRect(x: x, y: y, width: width, height: height),
        label: label,
        role: source == .accessibility ? "AXButton" : nil,
        source: source,
        appName: appName,
        windowID: windowID,
        zIndex: zIndex
    )
}

func makeWindow(
    id: CGWindowID,
    x: CGFloat = 0,
    y: CGFloat = 0,
    width: CGFloat = 800,
    height: CGFloat = 600,
    zIndex: Int = 0
) -> ScreenWindow {
    ScreenWindow(
        id: id,
        pid: 1,
        appName: "TestApp",
        bounds: CGRect(x: x, y: y, width: width, height: height),
        zIndex: zIndex
    )
}
