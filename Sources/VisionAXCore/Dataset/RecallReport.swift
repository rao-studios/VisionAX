//
//  RecallReport.swift
//  VisionAXCore
//
//  WHAT: How much of the ground truth Canny actually proposed, by role and by size.
//  IN:   ProposalMatcher
//  OUT:  harvest run log, Dataset/manifest.json, the case for a learned detector
//  PIN:  THIS IS THE CEILING ON THE WHOLE PIPELINE. A classifier can only name boxes
//        the detector produced, so a role with 20% proposal recall is capped at 20%
//        no matter how good the model gets. Read this table before blaming the model.
//

import Foundation

public struct RecallTally: Codable, Sendable, Equatable {
    public var total: Int
    public var found: Int

    public init(total: Int = 0, found: Int = 0) {
        self.total = total
        self.found = found
    }

    public var rate: Double { total > 0 ? Double(found) / Double(total) : 0 }

    public static func + (lhs: RecallTally, rhs: RecallTally) -> RecallTally {
        RecallTally(total: lhs.total + rhs.total, found: lhs.found + rhs.found)
    }
}

public struct RecallReport: Codable, Sendable, Equatable {
    public var overall: RecallTally
    public var byRole: [String: RecallTally]
    public var bySize: [String: RecallTally]

    public init(
        overall: RecallTally = RecallTally(),
        byRole: [String: RecallTally] = [:],
        bySize: [String: RecallTally] = [:]
    ) {
        self.overall = overall
        self.byRole = byRole
        self.bySize = bySize
    }

    /// Short-side buckets. A 12pt checkbox and a 900pt panel fail for opposite reasons,
    /// and one blended number hides both.
    public static let sizeBuckets = ["<16", "16-32", "32-64", ">64"]

    public static func sizeBucket(forShortSide side: Int) -> String {
        switch side {
        case ..<16: return "<16"
        case ..<32: return "16-32"
        case ..<64: return "32-64"
        default: return ">64"
        }
    }

    public func merged(with other: RecallReport) -> RecallReport {
        var byRole = self.byRole
        for (role, tally) in other.byRole {
            byRole[role] = (byRole[role] ?? RecallTally()) + tally
        }
        var bySize = self.bySize
        for (bucket, tally) in other.bySize {
            bySize[bucket] = (bySize[bucket] ?? RecallTally()) + tally
        }
        return RecallReport(overall: overall + other.overall, byRole: byRole, bySize: bySize)
    }

    /// A fixed-width table for the harvest log. Roles sorted worst-recall first, because
    /// the bottom of that list is the tuning work.
    public func formattedTable() -> String {
        var lines: [String] = []
        lines.append("proposal recall  \(overall.found)/\(overall.total)  \(percent(overall.rate))")
        lines.append("")
        lines.append("  role                    found/total   recall")
        for (role, tally) in byRole.sorted(by: { ($0.value.rate, $0.key) < ($1.value.rate, $1.key) }) {
            let count = "\(tally.found)/\(tally.total)"
            lines.append("  \(pad(role, 22))  \(pad(count, 11))   \(percent(tally.rate))")
        }
        lines.append("")
        lines.append("  short side              found/total   recall")
        for bucket in Self.sizeBuckets {
            guard let tally = bySize[bucket] else { continue }
            let count = "\(tally.found)/\(tally.total)"
            lines.append("  \(pad(bucket, 22))  \(pad(count, 11))   \(percent(tally.rate))")
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func percent(_ rate: Double) -> String {
        String(format: "%5.1f%%", rate * 100)
    }
}
