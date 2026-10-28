import Foundation
import IOKit.hid

/// Thin IOHIDManager wrapper for one matched device. Every IOKit callback is
/// scheduled on the main run loop, so the whole object lives on the main actor.
@MainActor
final class HIDTransport {
    var onReport: (([UInt8]) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private(set) var device: IOHIDDevice?

    private let manager: IOHIDManager
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
    private static let inputBufferSize = 1024

    init(vendorID: Int, productID: Int) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().detach(device)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Starts matching. A non-success code means macOS refused access to the HID interface.
    func start() -> IOReturn {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var serialNumber: String? { property(kIOHIDSerialNumberKey) as? String }
    var productName: String? { property(kIOHIDProductKey) as? String }
    var manufacturer: String? { property(kIOHIDManufacturerKey) as? String }

    private func property(_ key: String) -> Any? {
        device.flatMap { IOHIDDeviceGetProperty($0, key as CFString) }
    }

    /// Sends one output report. `report[0]` must be the report ID.
    @discardableResult
    func send(_ report: [UInt8]) -> Bool {
        guard let device, let id = report.first else { return false }
        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), buffer.baseAddress!, buffer.count)
        }
        return result == kIOReturnSuccess
    }

    private func attach(_ device: IOHIDDevice) {
        guard self.device == nil else { return }   // one Black Pearl at a time
        self.device = device
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, Self.inputBufferSize, { context, _, _, _, reportID, report, length in
            guard let context, length > 0 else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // IOKit delivers numbered reports with the ID as byte 0; normalise in case it doesn't.
            let id = UInt8(truncatingIfNeeded: reportID)
            if reportID != 0, bytes[0] != id { bytes.insert(id, at: 0) }
            MainActor.assumeIsolated {
                Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().onReport?(bytes)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        onConnection?(true)
    }

    private func detach(_ device: IOHIDDevice) {
        guard let current = self.device, CFEqual(current, device) else { return }
        self.device = nil
        onConnection?(false)
    }
}
