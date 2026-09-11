//
//  DatasetWriter.swift
//  VisionAXCore
//
//  WHAT: The on-disk dataset — images, samples, the role table, the run manifest.
//  IN:   VisionAXHarvestKit
//  OUT:  Dataset/ → Training/visionax_train/dataset.py, bench ground-truth toggle
//  PIN:  roles.json CARRIES THE CATEGORY, written from AXNodeCategory here in Swift.
//        Python must never own a second copy of Mary's role→category table: the
//        category-accuracy metric would then measure agreement with a stale duplicate
//        instead of with Mary. Writes are atomic because a harvest is long and a
//        half-written sample would fail a training run hours later, far from the cause.
//        THE ENGINE VERSION IS THE CALLER'S TO SUPPLY. This module describes a dataset
//        and has no engine to ask; the harvester passes Frigate's `VisionAX.version`.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One row of `roles.json` — the vocabulary as Python receives it.
public struct RoleTableEntry: Codable, Sendable, Equatable {
    public var index: Int
    public var role: String
    public var category: String

    public init(index: Int, role: String, category: String) {
        self.index = index
        self.role = role
        self.category = category
    }
}

public struct DatasetManifest: Codable, Sendable, Equatable {
    public struct Run: Codable, Sendable, Equatable {
        public var id: String
        public var source: HarvestSource
        public var startedAt: Date
        public var count: Int
        public var canny: CannyOptions
        public var recall: RecallReport?

        public init(
            id: String,
            source: HarvestSource,
            startedAt: Date,
            count: Int,
            canny: CannyOptions,
            recall: RecallReport? = nil
        ) {
            self.id = id
            self.source = source
            self.startedAt = startedAt
            self.count = count
            self.canny = canny
            self.recall = recall
        }
    }

    public var version: Int
    public var engineVersion: String
    public var runs: [Run]

    public init(version: Int = 1, engineVersion: String, runs: [Run] = []) {
        self.version = version
        self.engineVersion = engineVersion
        self.runs = runs
    }
}

public enum DatasetWriterError: Error, CustomStringConvertible {
    case pngEncodingFailed(String)

    public var description: String {
        switch self {
        case .pngEncodingFailed(let id): return "could not encode \(id) as PNG"
        }
    }
}

public final class DatasetWriter {
    public let root: URL
    /// Stamped into the manifest on every run, so a training set says which detector
    /// proposed its boxes.
    public let engineVersion: String
    public var imagesDirectory: URL { root.appendingPathComponent("images", isDirectory: true) }
    public var samplesDirectory: URL { root.appendingPathComponent("samples", isDirectory: true) }
    public var rolesURL: URL { root.appendingPathComponent("roles.json") }
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    private let fileManager = FileManager.default

    public init(root: URL, engineVersion: String) throws {
        self.root = root
        self.engineVersion = engineVersion
        for directory in [root, imagesDirectory, samplesDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Writes the vocabulary with each role's Mary category alongside it.
    public func writeRoles(_ vocabulary: RoleVocabulary) throws {
        let table = vocabulary.roles.enumerated().map { index, role in
            RoleTableEntry(
                index: index,
                role: role,
                category: AXNodeCategory.category(role: role).rawValue)
        }
        try writeAtomically(try AXTreeJSON.encode(table), to: rolesURL)
    }

    /// The sample JSON plus its PNG. Both land or neither does.
    public func write(sample: HarvestSample, image: CGImage) throws {
        let imageURL = imagesDirectory.appendingPathComponent("\(sample.id).png")
        let sampleURL = samplesDirectory.appendingPathComponent("\(sample.id).json")
        guard let png = Self.pngData(from: image) else {
            throw DatasetWriterError.pngEncodingFailed(sample.id)
        }
        // Image first: a sample whose image is missing breaks a training run, while an
        // image with no sample is merely ignored.
        try png.write(to: imageURL, options: .atomic)
        try writeAtomically(try AXTreeJSON.encode(sample), to: sampleURL)
    }

    public func loadManifest() throws -> DatasetManifest {
        guard let data = fileManager.contents(atPath: manifestURL.path) else {
            return DatasetManifest(engineVersion: engineVersion)
        }
        return try AXTreeJSON.decode(DatasetManifest.self, from: data)
    }

    /// Read-modify-write: a dataset accumulates across many harvest sessions.
    public func appendRun(_ run: DatasetManifest.Run) throws {
        var manifest = try loadManifest()
        manifest.engineVersion = engineVersion
        manifest.runs.removeAll { $0.id == run.id }
        manifest.runs.append(run)
        try writeAtomically(try AXTreeJSON.encode(manifest), to: manifestURL)
    }

    public func sampleIDs() throws -> [String] {
        let names = try fileManager.contentsOfDirectory(atPath: samplesDirectory.path)
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    public func loadSample(id: String) throws -> HarvestSample {
        let url = samplesDirectory.appendingPathComponent("\(id).json")
        return try AXTreeJSON.decode(HarvestSample.self, from: Data(contentsOf: url))
    }

    // MARK: - Plumbing

    private func writeAtomically(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
