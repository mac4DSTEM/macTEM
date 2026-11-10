//
//  SEMImageSettingsTests.swift
//  The SEM image display's one stored switch (`SEMImageSettings`, #341): the vendor's databar is hidden unless the person chose
//  to show it, the choice is kept under one key, and it is read from and written to the defaults the caller passes. Each test
//  has defaults of its own, removed after it; none touches the app's.
//  Red under: off by default, the choice not kept, another key (a choice made in an earlier version would be lost), the passed
//  defaults ignored.
//

import XCTest
@testable import macTEM

nonisolated final class SEMImageSettingsTests: XCTestCase {

    /// Defaults of the test's own, removed after it.
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "mactem-sem-image-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Nothing stored: the databar is hidden. A stored choice is read back, and removing it gives the default again.
    func testTheDatabarIsHiddenUnlessThePersonChoseToShowIt() throws {
        let defaults = try scratchDefaults()
        XCTAssertNil(defaults.object(forKey: SEMImageSettings.cropDatabarKey), "setup: nothing is stored yet")
        XCTAssertTrue(SEMImageSettings.cropDatabar(defaults), "on by default")
        SEMImageSettings.setCropDatabar(false, defaults)
        XCTAssertFalse(SEMImageSettings.cropDatabar(defaults))
        SEMImageSettings.setCropDatabar(true, defaults)
        XCTAssertTrue(SEMImageSettings.cropDatabar(defaults))
        SEMImageSettings.setCropDatabar(false, defaults)
        defaults.removeObject(forKey: SEMImageSettings.cropDatabarKey)
        XCTAssertTrue(SEMImageSettings.cropDatabar(defaults), "no stored choice is the default again")
    }

    /// The choice is a Boolean under `sem.cropDatabar`, in the defaults it was given and in no other.
    func testTheChoiceIsKeptUnderItsKeyInTheDefaultsItWasGiven() throws {
        XCTAssertEqual(SEMImageSettings.cropDatabarKey, "sem.cropDatabar")
        let first = try scratchDefaults()
        let second = try scratchDefaults()
        SEMImageSettings.setCropDatabar(false, first)
        XCTAssertEqual(first.object(forKey: "sem.cropDatabar") as? Bool, false)
        XCTAssertNil(second.object(forKey: "sem.cropDatabar"), "another store is not written")
        XCTAssertTrue(SEMImageSettings.cropDatabar(second))
        // A value another build wrote under the key is read: off stays off.
        second.set(false, forKey: "sem.cropDatabar")
        XCTAssertFalse(SEMImageSettings.cropDatabar(second))
    }
}
