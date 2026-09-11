// ReplyTopicQRCode.swift. A QR code for the reply inbox address, so
// subscribing a phone is one scan instead of typing a 16-character topic
// off a laptop screen.
//
// CoreImage's own generator, no dependency and no network. The whole file
// is one pure function on purpose: it takes a URL and returns an image,
// holds nothing, caches nothing, and has no idea what the URL means. The
// decision about WHETHER an address may be drawn at all lives upstream in
// `HoverViewModel.remoteReplyInboxQRTarget()`, which returns nil until the
// owner has explicitly revealed the topic.
//
// That split matters more than it looks. A QR image is the topic in a form
// a camera reads from across a room, so it is strictly worse than the text
// for a shoulder-surfer and exactly as bad for a screenshot. Putting the
// gate in the view model rather than here means the reveal rule is one
// testable function covering both the text and the image, instead of two
// rules in two files that can drift.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum ReplyTopicQRCode {

    /// Rendered edge length in points. Small enough to sit in a 480pt-wide
    /// panel row, big enough that a phone camera locks onto it at arm's
    /// length.
    public static let sidePoints: CGFloat = 96

    /// Draw `url` as a QR code, or nil when CoreImage declines.
    ///
    /// `.medium` correction rather than the default `.low`: the image is
    /// read off a glossy laptop screen, often at an angle, and the extra
    /// redundancy costs a slightly denser code and nothing else.
    ///
    /// Returns nil rather than a placeholder on failure. A blank square
    /// where a QR should be is a thing the owner tries to scan; no square
    /// at all sends them to the text address next to it, which works.
    public static func image(for url: URL, sidePoints: CGFloat = ReplyTopicQRCode.sidePoints) -> NSImage? {
        let payload = url.absoluteString
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The generator emits one pixel per module, so scale up before
        // rasterizing: letting AppKit interpolate a 25pt image up to 96pt
        // produces soft edges that phone cameras hunt for and sometimes
        // miss. An integer scale keeps every module a whole number of
        // pixels, which is what makes the result crisp.
        let scale = max(1, (sidePoints / max(output.extent.width, 1)).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: sidePoints, height: sidePoints))
        image.isTemplate = false
        return image
    }
}
