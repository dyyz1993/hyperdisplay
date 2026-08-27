import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct VirtualDisplayGeometryTests {
    static func main() {
        let tablet = VirtualDisplayGeometry(pixelWidth: 2800, pixelHeight: 1840)
        check(tablet?.logicalWidth == 1400 && tablet?.logicalHeight == 920,
              "native tablet pixels must map to half-sized Retina points")
        check(tablet?.backingScale == 2, "Retina backing scale")
        check(tablet?.modeCompatibility(actualLogicalWidth: 1400, actualLogicalHeight: 920,
                                        actualPixelWidth: 2800, actualPixelHeight: 1840) == .requested,
              "the exact requested Retina mode must be accepted")
        check(tablet?.modeCompatibility(actualLogicalWidth: 2800, actualLogicalHeight: 1840,
                                        actualPixelWidth: 2800, actualPixelHeight: 1840) == .incompatible,
              "a system 1x fallback must never satisfy a strict Retina request")
        check(tablet?.modeCompatibility(actualLogicalWidth: 1920, actualLogicalHeight: 1200,
                                        actualPixelWidth: 1920, actualPixelHeight: 1200) == .incompatible,
              "an unrelated system mode must still be rejected")

        let splitPane = VirtualDisplayGeometry(pixelWidth: 1408, pixelHeight: 1840)
        check(splitPane?.logicalWidth == 704 && splitPane?.logicalHeight == 920,
              "split panes keep their complete physical pixel backing")

        check(VirtualDisplayGeometry(pixelWidth: 720, pixelHeight: 960) == nil,
              "compact split panes must reject unsupported strict Retina before CGVirtualDisplay creation")

        let legacy = VirtualDisplayGeometry(pixelWidth: 1920, pixelHeight: 1200, retina: false)
        check(legacy?.logicalWidth == 1920 && legacy?.logicalHeight == 1200 && legacy?.backingScale == 1,
              "explicit 1x fallback keeps the original canvas")

        check(VirtualDisplayGeometry(pixelWidth: 2131, pixelHeight: 1080) == nil,
              "large 2x candidates must reject odd dimensions before touching CGVirtualDisplay")
        print("Virtual display geometry tests passed")
    }
}
