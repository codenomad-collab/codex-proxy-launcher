@testable import CodexProxyLauncherCore
import XCTest

final class ProxyIPInfoServiceTests: XCTestCase {
    func testDecodesIPWhoResponse() throws {
        let json = """
        {
          "success": true,
          "ip": "203.0.113.7",
          "type": "IPv4",
          "continent": "North America",
          "country": "United States",
          "country_code": "US",
          "region": "California",
          "city": "Los Angeles",
          "latitude": 34.05,
          "longitude": -118.24,
          "connection": {
            "asn": 64500,
            "org": "Example Network",
            "isp": "Example ISP",
            "domain": "example.test"
          },
          "timezone": { "id": "America/Los_Angeles", "abbr": "PDT" }
        }
        """

        let info = try ProxyIPInfoService.decode(Data(json.utf8))

        XCTAssertEqual(info.ip, "203.0.113.7")
        XCTAssertEqual(info.countryFlag, "🇺🇸")
        XCTAssertEqual(info.locationSummary, "Los Angeles · California · United States")
        XCTAssertEqual(info.networkSummary, "AS64500 · Example ISP")
        XCTAssertEqual(info.timezone, "America/Los_Angeles")
    }

    func testRejectsServiceFailure() {
        let json = #"{"success":false,"message":"rate limit"}"#
        XCTAssertThrowsError(
            try ProxyIPInfoService.decode(Data(json.utf8))
        )
    }
}
