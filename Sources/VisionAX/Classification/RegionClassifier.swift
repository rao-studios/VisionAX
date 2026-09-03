//
//  RegionClassifier.swift
//  VisionAX
//
//  WHAT: A loaded model — two ONNX graphs plus the vocabulary that names their output.
//  IN:   a spec JSON on disk, or the one bundled in Resources/Models
//  OUT:  VisionEngine.classifyRegions
//  PIN:  The two .onnx files are git-lfs objects. A clone without `git lfs pull` leaves
//        130-byte TEXT pointers in their place, and handing one to ONNX Runtime yields
//        "Protobuf parsing failed" — a message that sends you looking at the model
//        instead of at git. So the pointer is detected here, by name, and said out loud.
//        The C engine holds no per-call state, so one classifier serves many threads.
//

import CVisionAX
import Foundation

public enum RegionClassifierError: Error, CustomStringConvertible {
    case specUnreadable(URL, String)
    case unsupportedSpecFormat(Int)
    case unexpectedTensorNames(ClassifierSpec.IO)
    case malformedSpec(String)
    case vocabulary(RoleVocabularyError)
    case modelMissing(URL)
    case modelIsLFSPointer(URL)
    case modelFailed(String)
    case labelCountMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .specUnreadable(let url, let reason):
            return "could not read the model spec at \(url.path): \(reason)"
        case .unsupportedSpecFormat(let format):
            return "model spec format \(format) — this build understands "
                + "\(ClassifierSpec.supportedFormat)"
        case .unexpectedTensorNames(let io):
            return "the spec names its tensors \(io.image)/\(io.features)/\(io.boxes)/\(io.probs); "
                + "the engine binds image/features/boxes/probs"
        case .malformedSpec(let reason):
            return "the model spec is not one this engine can serve: \(reason)"
        case .vocabulary(let error):
            return "the model's vocabulary is unusable: \(error)"
        case .modelMissing(let url):
            return "the model file \(url.lastPathComponent) is missing from \(url.deletingLastPathComponent().path)"
        case .modelIsLFSPointer(let url):
            return "\(url.lastPathComponent) is a git-lfs pointer, not a model — run `git lfs pull`"
        case .modelFailed(let message):
            return "ONNX Runtime rejected the model: \(message)"
        case .labelCountMismatch(let expected, let got):
            return "asked for \(expected) labels, the engine returned \(got)"
        }
    }
}

public final class RegionClassifier: @unchecked Sendable {
    /// `vx_classifier` is opaque in the header, so it arrives as an OpaquePointer.
    let handle: OpaquePointer
    public let spec: ClassifierSpec
    public let vocabulary: RoleVocabulary

    /// The confidence below which a region keeps `VXRegion` — calibrated at training
    /// time and carried in the spec, so serving does not need to re-guess it.
    public var minimumConfidence: Double { spec.minConfidence }

    /// `specURL` names a JSON sidecar; the two .onnx paths inside it are resolved
    /// relative to that file, so a model directory can be copied anywhere as a unit.
    public init(specURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: specURL)
        } catch {
            throw RegionClassifierError.specUnreadable(specURL, error.localizedDescription)
        }
        let decoded: ClassifierSpec
        do {
            decoded = try AXTreeJSON.decode(ClassifierSpec.self, from: data)
        } catch {
            throw RegionClassifierError.specUnreadable(specURL, "\(error)")
        }
        let spec = try decoded.validated()

        let directory = specURL.deletingLastPathComponent()
        let backbone = directory.appendingPathComponent(spec.files.backbone)
        let head = directory.appendingPathComponent(spec.files.head)
        try Self.requireRealModel(at: backbone)
        try Self.requireRealModel(at: head)

        var cSpec = spec.toC()
        var created: OpaquePointer?
        let status = backbone.path.withCString { backbonePath in
            head.path.withCString { headPath in
                vx_classifier_create(backbonePath, headPath, &cSpec, &created)
            }
        }
        guard status == VX_OK, let created else {
            throw RegionClassifierError.modelFailed(String(cString: vx_classifier_last_error(nil)))
        }

        self.handle = created
        self.spec = spec
        self.vocabulary = spec.vocabulary
    }

    deinit {
        vx_classifier_destroy(handle)
    }

    /// The model shipped in the package's resources, or nil when none was bundled.
    /// Throws only when a model IS there but cannot be loaded — a missing model is a
    /// configuration, a broken one is a fault.
    ///
    /// PIN: `Bundle.module` IS TOUCHED LAST, AND THAT ORDER IS LOAD-BEARING. SwiftPM
    /// generates an accessor that calls `fatalError` when the resource bundle is not
    /// beside the executable — so inside a copied .app, reaching for it first would
    /// TRAP rather than return nil. Looking in the host app's own Resources first means
    /// a properly assembled bundle never reaches the trapping path, and a machine with
    /// neither gets an honest nil.
    public static func bundled(searching extra: [URL] = []) throws -> RegionClassifier? {
        for directory in extra + [Self.hostBundleModels].compactMap({ $0 }) {
            let spec = directory.appendingPathComponent("region-classifier.json")
            if FileManager.default.fileExists(atPath: spec.path) {
                return try RegionClassifier(specURL: spec)
            }
        }
        guard let url = Bundle.module.url(
            forResource: "region-classifier", withExtension: "json", subdirectory: "Models")
        else { return nil }
        return try RegionClassifier(specURL: url)
    }

    /// Where a host application copies this package's resource bundle — the layout
    /// `make-app.sh`-style assembly produces.
    static var hostBundleModels: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("VisionAX_VisionAX.bundle")
            .appendingPathComponent("Models")
    }

    /// The directory the model was actually loaded from, for a probe to print. Nil when
    /// no model is reachable at all — which is a state the media lane survives.
    public static func resourceBundleLocation() -> URL? {
        if let host = hostBundleModels,
           FileManager.default.fileExists(
            atPath: host.appendingPathComponent("region-classifier.json").path) {
            return host
        }
        return Bundle.module.url(
            forResource: "region-classifier", withExtension: "json", subdirectory: "Models")?
            .deletingLastPathComponent()
    }

    /// Run counters, for proving one image costs one backbone pass.
    public var runCounts: (backbone: Int, head: Int) {
        let stats = vx_classifier_get_stats(handle)
        return (Int(stats.backbone_runs), Int(stats.head_runs))
    }

    /// The engine's own words about the last failure on this classifier.
    var lastError: String {
        String(cString: vx_classifier_last_error(handle))
    }

    /// Turns a raw class index into the label callers see.
    func label(classIndex: Int32, confidence: Float) -> RegionLabel {
        RegionLabel(
            classIndex: Int(classIndex),
            role: vocabulary.role(at: Int(classIndex)) ?? RoleVocabulary.noneRole,
            confidence: Double(confidence))
    }

    private static func requireRealModel(at url: URL) throws {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw RegionClassifierError.modelMissing(url)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        // git-lfs pointer files begin with exactly this line.
        if head.starts(with: Data("version https://git-lfs.github.com/spec".utf8)) {
            throw RegionClassifierError.modelIsLFSPointer(url)
        }
    }
}
