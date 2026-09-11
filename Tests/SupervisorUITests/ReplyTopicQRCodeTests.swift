// ReplyTopicQRCodeTests.swift
//
// The QR the panel draws for the reply inbox topic. The test that matters
// is the round trip: generate, then DECODE the pixels back with CoreImage's
// own detector and compare against the URL that went in. A QR that renders
// as a plausible-looking square but scans to nothing, or to a truncated
// address, is a bug the owner discovers standing in a kitchen holding a
// phone, and it looks exactly like a correct image from here.
//
// Nothing in this file decides WHETHER a topic may be drawn. That gate is
// `HoverViewModel.remoteReplyInboxQRTarget()`, covered in
// RemoteReplyPanelTests, which returns nil until the owner reveals it.

import XCTest
import CoreImage
@testable import SupervisorUI

final class ReplyTopicQRCodeTests: XCTestCase {

    private func decode(_ image: NSImage) throws -> String {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let ciImage = CIImage(cgImage: cgImage)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: ciImage).compactMap { $0 as? CIQRCodeFeature }
        return try XCTUnwrap(features.first?.messageString, "the image did not scan as a QR code")
    }

    func testTheImageScansBackToTheExactURL() throws {
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/hDs8dpM3zLpTGGQEabcd"))
        let image = try XCTUnwrap(ReplyTopicQRCode.image(for: url))
        XCTAssertEqual(try decode(image), url.absoluteString)
    }

    func testASelfHostedServerWithAPortSurvivesTheRoundTrip() throws {
        // Self-hosted ntfy is the case the explicit `ntfy` format pill
        // exists for, and its URL carries a port and sometimes a longer
        // topic. Both are more characters to encode than ntfy.sh needs.
        let url = try XCTUnwrap(URL(string: "https://ntfy.internal.example:8443/aVeryLongSelfHostedTopicName123456"))
        let image = try XCTUnwrap(ReplyTopicQRCode.image(for: url))
        XCTAssertEqual(try decode(image), url.absoluteString)
    }

    func testTheImageIsRenderedAtTheRequestedSize() throws {
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/hDs8dpM3zLpTGGQEabcd"))
        let image = try XCTUnwrap(ReplyTopicQRCode.image(for: url))
        XCTAssertEqual(image.size.width, ReplyTopicQRCode.sidePoints)
        XCTAssertEqual(image.size.height, ReplyTopicQRCode.sidePoints)
    }

    func testAnUpscaledCodeStillScans() throws {
        // The generator emits one pixel per module. The upscale is what
        // makes a phone camera lock on, so a scale bug would show up as a
        // code that reads at one size and not another.
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/hDs8dpM3zLpTGGQEabcd"))
        for side in [64, 96, 160] as [CGFloat] {
            let image = try XCTUnwrap(ReplyTopicQRCode.image(for: url, sidePoints: side))
            XCTAssertEqual(try decode(image), url.absoluteString, "failed at \(side)pt")
        }
    }
}
