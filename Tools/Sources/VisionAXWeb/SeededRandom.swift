//
//  SeededRandom.swift
//  VisionAXWeb
//
//  WHAT: A deterministic generator, so a seed names a page exactly.
//  IN:   SyntheticPageGenerator
//  OUT:  RandomNumberGenerator
//  PIN:  SplitMix64 rather than SystemRandomNumberGenerator, because a dataset sample
//        stores its seed and nothing else about how the page was built. If the same
//        seed stopped producing the same page, every stored sample would become
//        unreproducible — and Swift makes no promise at all about the system
//        generator's sequence across processes or releases.
//

import Foundation

/// SplitMix64 — small, fast, and specified, which is the property that matters here.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // A zero seed in SplitMix64 is legal but starts in a corner of the sequence;
        // nudging it keeps low seeds (0, 1, 2) well separated.
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Conveniences the generator leans on

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    public mutating func bool(chance: Double = 0.5) -> Bool {
        double(in: 0...1) < chance
    }

    public mutating func pick<T>(_ options: [T]) -> T {
        options[int(in: 0...(options.count - 1))]
    }

    /// `count` distinct picks in a shuffled order.
    public mutating func sample<T>(_ options: [T], count: Int) -> [T] {
        var pool = options
        var chosen: [T] = []
        while chosen.count < count, !pool.isEmpty {
            chosen.append(pool.remove(at: int(in: 0...(pool.count - 1))))
        }
        return chosen
    }
}
