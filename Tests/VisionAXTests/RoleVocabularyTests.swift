//
//  RoleVocabularyTests.swift
//  VisionAXTests
//
//  WHAT: The vocabulary is closed and every role in it is one Mary can act on.
//  PIN:  The first test is the whole Mary-safety contract in one assertion. If a role
//        is ever added that categorizes as .other, Mary would read the classified node,
//        throw away its label, and drop it from every roster — the model would look
//        like it was working while Mary saw nothing.
//

import Foundation
import Testing
@testable import VisionAX

@Suite struct RoleVocabularyTests {

    @Test func everyStandardRoleIsOneMaryActsOn() throws {
        let vocabulary = try RoleVocabulary.standard.validated()
        for role in vocabulary.roles.dropFirst() {
            let category = AXNodeCategory.category(role: role)
            #expect(category != .other, "\(role) would be discarded by Mary")
        }
    }

    @Test func theStandardVocabularyHasTwentyThreeClasses() {
        #expect(RoleVocabulary.standard.classCount == 23)
        #expect(RoleVocabulary.standard.roles[0] == "none")
    }

    @Test func indexAndRoleAreInverses() {
        let vocabulary = RoleVocabulary.standard
        for (index, role) in vocabulary.roles.enumerated() {
            #expect(vocabulary.index(of: role) == index)
            #expect(vocabulary.role(at: index) == role)
        }
        #expect(vocabulary.role(at: 999) == nil)
        #expect(vocabulary.index(of: "AXNotARole") == nil)
    }

    @Test func noneIsAlwaysClassZero() {
        #expect(RoleVocabulary.standard.isNone(0))
        #expect(!RoleVocabulary.standard.isNone(1))
    }

    @Test func validationRejectsARoleMaryWouldDiscard() {
        // AXWebArea is a real role, but it categorizes as .webArea... use one that
        // genuinely falls through: AXUnknown.
        let bad = RoleVocabulary(roles: ["none", "AXButton", "AXUnknown"])
        #expect(throws: RoleVocabularyError.roleMaryWouldDiscard("AXUnknown")) {
            try bad.validated()
        }
    }

    @Test func validationRejectsAMisplacedNone() {
        let bad = RoleVocabulary(roles: ["AXButton", "none"])
        #expect(throws: RoleVocabularyError.firstClassIsNotNone("AXButton")) {
            try bad.validated()
        }
    }

    @Test func validationRejectsDuplicates() {
        let bad = RoleVocabulary(roles: ["none", "AXButton", "AXButton"])
        #expect(throws: RoleVocabularyError.duplicateRole("AXButton")) {
            try bad.validated()
        }
    }

    @Test func aLabelNamesOnlyAboveItsThreshold() {
        let confident = RegionLabel(classIndex: 1, role: "AXButton", confidence: 0.9)
        #expect(confident.names(atLeast: 0.6))
        #expect(!confident.names(atLeast: 0.95))

        // Class 0 never names anything, however sure the model is.
        let none = RegionLabel(classIndex: 0, role: "none", confidence: 1.0)
        #expect(!none.names(atLeast: 0.0))
    }
}
