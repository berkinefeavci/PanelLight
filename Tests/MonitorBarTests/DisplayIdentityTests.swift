import XCTest
@testable import MonitorBar

final class DisplayIdentityTests: XCTestCase {
    func testMatchesByFullIdentity() {
        let displays = [
            DisplayIdentity(id: 4, name: "A", vendor: 0x598b, product: 0x2700, serial: 1),
            DisplayIdentity(id: 5, name: "B", vendor: 0x598b, product: 0x2700, serial: 2),
        ]
        let services = [
            DDCIdentity(index: 8, vendor: 0x598b, product: 0x2700, serial: 2),
            DDCIdentity(index: 7, vendor: 0x598b, product: 0x2700, serial: 1),
        ]
        XCTAssertEqual(matchDisplays(displays, to: services), [4: 7, 5: 8])
    }

    func testRejectsAmbiguousTwins() {
        let displays = [
            DisplayIdentity(id: 4, name: "A", vendor: 0x598b, product: 0x2700, serial: 0),
            DisplayIdentity(id: 5, name: "B", vendor: 0x598b, product: 0x2700, serial: 0),
        ]
        let services = [
            DDCIdentity(index: 0, vendor: 0x598b, product: 0x2700, serial: 0),
            DDCIdentity(index: 1, vendor: 0x598b, product: 0x2700, serial: 0),
        ]
        XCTAssertTrue(matchDisplays(displays, to: services).isEmpty)
    }

    func testSingleDisplaySingleServiceFallback() {
        let display = DisplayIdentity(id: 4, name: "A", vendor: 0x598b, product: 0x2700, serial: 0)
        let service = DDCIdentity(index: 3, vendor: 0, product: 0, serial: 0)
        XCTAssertEqual(matchDisplays([display], to: [service]), [4: 3])
    }

    func testRejectsInvalidLevelsAndClampsInput() {
        XCTAssertNil(percent(current: 1, maximum: 0))
        XCTAssertNil(percent(current: 101, maximum: 100))
        XCTAssertEqual(percent(current: 58, maximum: 100)!, 58, accuracy: 0.0001)
        XCTAssertNil(rawLevel(percent: 50, maximum: 0))
        XCTAssertEqual(rawLevel(percent: -5, maximum: 100), 0)
        XCTAssertEqual(rawLevel(percent: 140, maximum: 100), 100)
        XCTAssertEqual(rawLevel(percent: 50, maximum: 255), 128)
    }

    // Paths read on a MacBook Pro (M5 Pro) with a TCL 27G64 on USB-C.
    func testFramebufferPortComesFromBothSides() {
        XCTAssertEqual(framebufferPort(fromDisplayLocation:
            "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext0@B0000000/IOMobileFramebufferShim"), "dispext0")
        XCTAssertEqual(framebufferPort(fromDisplayLocation:
            "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/disp0@88000000/IOMobileFramebufferShim"), "disp0")
        XCTAssertEqual(framebufferPort(fromServicePath:
            "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dcpext0@B2E00000/AppleASCWrapV6/iop-dcpext0-nub/RTBuddy(DCPEXT0)/DCPEXT0Endpoint11/AFKDCPEXT0Endpoint11/AFKEPInterfaceServiceKextV2/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"),
            "dispext0")
        XCTAssertEqual(framebufferPort(fromServicePath: "IOService:/x/dispext12:dcpav-service-epic:0/DCPAVServiceProxy"), "dispext12")
        XCTAssertNil(framebufferPort(fromServicePath: "IOService:/x/dcpext0@B2E00000/DCPAVServiceProxy"))
        XCTAssertNil(framebufferPort(fromDisplayLocation: "IOService:/x/display@1/IOMobileFramebufferShim"))
        XCTAssertNil(framebufferPort(fromDisplayLocation: ""))
    }

    func testIdenticalMonitorsWithPlaceholderSerialsMatchByPort() {
        // Two 27G64s report the same EDID serial (0xFFFFFFFF): EDID alone cannot tell them apart.
        let displays = [
            DisplayIdentity(id: 3, name: "27G64", vendor: 0x506c, product: 0x1002, serial: 0xFFFF_FFFF, port: "dispext0"),
            DisplayIdentity(id: 4, name: "27G64", vendor: 0x506c, product: 0x1002, serial: 0xFFFF_FFFF, port: "dispext1"),
        ]
        let services = [
            DDCIdentity(index: 0, vendor: 0x506c, product: 0x1002, serial: 0xFFFF_FFFF, port: "dispext1"),
            DDCIdentity(index: 1, vendor: 0x506c, product: 0x1002, serial: 0xFFFF_FFFF, port: "dispext0"),
        ]
        XCTAssertEqual(matchDisplays(displays, to: services), [3: 1, 4: 0])
        let withoutPorts = displays.map { DisplayIdentity(id: $0.id, name: $0.name, vendor: $0.vendor,
                                                          product: $0.product, serial: $0.serial) }
        XCTAssertTrue(matchDisplays(withoutPorts, to: services).isEmpty, "without ports they stay ambiguous")
    }

    func testPortMatchYieldsToAnEDIDNamingAnotherMonitor() {
        let display = DisplayIdentity(id: 3, name: "A", vendor: 0x506c, product: 0x1002, serial: 7, port: "dispext0")
        let services = [
            DDCIdentity(index: 0, vendor: 0x10ac, product: 0x4242, serial: 9, port: "dispext0"),
            DDCIdentity(index: 1, vendor: 0x506c, product: 0x1002, serial: 7, port: nil),
        ]
        XCTAssertEqual(matchDisplays([display], to: services), [3: 1])
    }

    func testPortMatchTakesAServiceWithoutEDID() {
        let display = DisplayIdentity(id: 3, name: "A", vendor: 0x506c, product: 0x1002, serial: 7, port: "dispext0")
        let services = [
            DDCIdentity(index: 0, vendor: 0, product: 0, serial: 0, port: "dispext0"),
            DDCIdentity(index: 1, vendor: 0, product: 0, serial: 0, port: "dispext1"),
        ]
        XCTAssertEqual(matchDisplays([display], to: services), [3: 0])
    }
}
