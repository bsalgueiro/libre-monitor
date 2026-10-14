import Foundation
import LibreMonitorKit
import XCTest

// Port of tests/LibreMonitor.Core.Tests/GlucoseUnitsTests.cs

final class GlucoseUnitsTests: XCTestCase {
    private let invariant = Locale(identifier: "en_US_POSIX")

    func testMmolIsOneDecimal() {
        let cases: [(Double, String)] = [(70, "3.9"), (100, "5.5"), (180, "10.0"), (54, "3.0"), (400, "22.2")]
        for (mgPerDl, expected) in cases {
            XCTAssertEqual(GlucoseUnits.format(mgPerDl, unit: .mmolPerL, locale: invariant), expected, "\(mgPerDl) mg/dL")
        }
    }

    func testMgPerDlIsWholeNumber() {
        XCTAssertEqual(GlucoseUnits.format(112, unit: .mgPerDl, locale: invariant), "112")
        XCTAssertEqual(GlucoseUnits.format(111.6, unit: .mgPerDl, locale: invariant), "112")
    }

    func testFormatUsesTheCallersDecimalSeparator() {
        XCTAssertEqual(GlucoseUnits.format(100, unit: .mmolPerL, locale: Locale(identifier: "pt_PT")), "5,5")
    }

    func testLabelsAreConventional() {
        XCTAssertEqual(GlucoseUnit.mgPerDl.label, "mg/dL")
        XCTAssertEqual(GlucoseUnit.mmolPerL.label, "mmol/L")
    }

    func testTrendArrowsMatchTheWindowsApp() {
        XCTAssertEqual(Trend.downFast.arrow, "↓")
        XCTAssertEqual(Trend.downSlow.arrow, "↘")
        XCTAssertEqual(Trend.stable.arrow, "→")
        XCTAssertEqual(Trend.upSlow.arrow, "↗")
        XCTAssertEqual(Trend.upFast.arrow, "↑")
        XCTAssertEqual(Trend.unknown.arrow, "?")
    }
}
