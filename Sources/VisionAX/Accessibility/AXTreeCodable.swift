//
//  AXTreeCodable.swift
//  VisionAX
//
//  WHAT: The JSON shape of the AX tree, plus the house encoder/decoder.
//  IN:   VisionDetection.json, VisionAXBench JSON stage, Tests/Fixtures
//  OUT:  AXNodeSnapshot / AXWindowSnapshot / AXAppSnapshot / AXScreenElement
//  PIN:  Mary has no tree JSON — this file defines it. Rects are flat
//        {x, y, width, height} (Mary's AXFrameRect spelling), never CGRect's nested
//        origin/size. subtreeCount is written for readers but RECOMPUTED on decode, so
//        it cannot drift from children. Encoder settings match Mary's
//        AXFrameProjection.json: sorted keys, unescaped slashes, ISO-8601, trailing newline.
//

import CoreGraphics
import Foundation

// MARK: - Encoder / decoder

public enum AXTreeJSON {
    public static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Pretty output ends in a newline, the way a file should.
    public static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = true) throws -> String {
        var data = try encoder(prettyPrinted: prettyPrinted).encode(value)
        if prettyPrinted { data.append(0x0A) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decode(type, from: Data(json.utf8))
    }
}

// MARK: - Geometry

/// Four Doubles — the wire form of a CGRect.
struct AXCodableRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Leaves

extension AXNodeID: Codable {
    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension AXNodeCategory: Codable {}

// MARK: - AXNodeSnapshot

extension AXNodeSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, subrole, label, frame, isEnabled, isFocused, category, children, subtreeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AXNodeID.self, forKey: .id),
            role: try container.decode(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            frame: try container.decodeIfPresent(AXCodableRect.self, forKey: .frame)?.cgRect,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isFocused: try container.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false,
            category: try container.decode(AXNodeCategory.self, forKey: .category),
            children: try container.decodeIfPresent([AXNodeSnapshot].self, forKey: .children) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(frame.map(AXCodableRect.init), forKey: .frame)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isFocused, forKey: .isFocused)
        try container.encode(category, forKey: .category)
        try container.encode(children, forKey: .children)
        try container.encode(subtreeCount, forKey: .subtreeCount)
    }
}

// MARK: - AXWindowSnapshot

extension AXWindowSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, frame, isMain, isMinimized, isTruncated, root
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AXNodeID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            frame: try container.decodeIfPresent(AXCodableRect.self, forKey: .frame)?.cgRect,
            isMain: try container.decodeIfPresent(Bool.self, forKey: .isMain) ?? false,
            isMinimized: try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false,
            isTruncated: try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false,
            root: try container.decodeIfPresent(AXNodeSnapshot.self, forKey: .root)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(frame.map(AXCodableRect.init), forKey: .frame)
        try container.encode(isMain, forKey: .isMain)
        try container.encode(isMinimized, forKey: .isMinimized)
        try container.encode(isTruncated, forKey: .isTruncated)
        try container.encodeIfPresent(root, forKey: .root)
    }
}

// MARK: - AXAppSnapshot

extension AXAppSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case pid, bundleID, appName, windows, capturedAt, walkDuration, nodeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pid: try container.decode(pid_t.self, forKey: .pid),
            bundleID: try container.decodeIfPresent(String.self, forKey: .bundleID),
            appName: try container.decode(String.self, forKey: .appName),
            windows: try container.decodeIfPresent([AXWindowSnapshot].self, forKey: .windows) ?? [],
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            walkDuration: .seconds(try container.decodeIfPresent(Double.self, forKey: .walkDuration) ?? 0),
            nodeCount: try container.decode(Int.self, forKey: .nodeCount)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encode(appName, forKey: .appName)
        try container.encode(windows, forKey: .windows)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(walkDuration.seconds, forKey: .walkDuration)
        try container.encode(nodeCount, forKey: .nodeCount)
    }
}

// MARK: - AXScreenElement

extension AXScreenElement: Codable {
    private enum CodingKeys: String, CodingKey {
        case ordinal, id, pid, appName, windowID, windowTitle, role, subrole, category, label,
             frame, isEnabled, isFocused, containerTrail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ordinal: try container.decode(Int.self, forKey: .ordinal),
            id: try container.decode(AXNodeID.self, forKey: .id),
            pid: try container.decode(pid_t.self, forKey: .pid),
            appName: try container.decode(String.self, forKey: .appName),
            windowID: try container.decode(AXNodeID.self, forKey: .windowID),
            windowTitle: try container.decode(String.self, forKey: .windowTitle),
            role: try container.decode(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            category: try container.decode(AXNodeCategory.self, forKey: .category),
            label: try container.decode(String.self, forKey: .label),
            frame: try container.decode(AXCodableRect.self, forKey: .frame).cgRect,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isFocused: try container.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false,
            containerTrail: try container.decodeIfPresent([String].self, forKey: .containerTrail) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(id, forKey: .id)
        try container.encode(pid, forKey: .pid)
        try container.encode(appName, forKey: .appName)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(windowTitle, forKey: .windowTitle)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encode(category, forKey: .category)
        try container.encode(label, forKey: .label)
        try container.encode(AXCodableRect(frame), forKey: .frame)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isFocused, forKey: .isFocused)
        try container.encode(containerTrail, forKey: .containerTrail)
    }
}

// MARK: - Duration

extension Duration {
    /// Whole seconds plus the attosecond remainder, as one Double.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
