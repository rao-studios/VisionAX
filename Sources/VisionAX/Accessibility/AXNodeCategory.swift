//
//  AXNodeCategory.swift
//  VisionAX
//
//  WHAT: Coarse role/subrole → stroke family. Total: every role lands, .other included.
//        Twin of Mary's MaryComputerUse/Accessibility/AXNodeCategory.swift.
//  IN:   AX role string  OUT: OverlayRenderer stroke, AXTreeCodable
//  PIN:  String-backed here (Mary's is not) so the JSON spelling is the case name and
//        cannot drift with case order.
//

import Foundation

public enum AXNodeCategory: String, Sendable, Equatable, CaseIterable {
    case interactive
    case text
    case image
    case container
    case scrollArea
    /// The root of a rendered page — Safari's and Chromium's `AXWebArea`, and the same role
    /// an Electron/CEF app exposes for its renderer view.
    case webArea
    /// A node SYNTHESIZED by a scripting sub-engine, never walked from AX.
    case scripted
    case window
    case other

    /// Classify a node from its role/subrole alone. Subrole wins where it disambiguates (an
    /// `AXCloseButton` subrole on a generic button role is still interactive either way, so
    /// subrole only matters where the bare role is ambiguous.
    public static func category(role: String, subrole: String? = nil) -> AXNodeCategory {
        switch role {
        case "AXWindow", "AXSheet", "AXDrawer":
            return .window
        case "AXWebArea":
            return .webArea
        case "AXScrollArea":
            return .scrollArea
        case "AXImage":
            return .image
        case "AXStaticText", "AXHeading":
            return .text
        case "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
             "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
             "AXComboBox", "AXSlider", "AXTab", "AXMenuItem", "AXMenuBarItem":
            return .interactive
        case "AXGroup", "AXRow", "AXCell", "AXOutline", "AXTable", "AXList",
             "AXToolbar", "AXTabGroup", "AXSplitGroup", "AXLayoutArea":
            return .container
        default:
            return .other
        }
    }
}
