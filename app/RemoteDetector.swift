//
//  RemoteDetector.swift
//  SiriRemote (HyperVibe-derived HID discovery)
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid
import os

private let runtimeLogger = Logger(subsystem: "com.deanxi.siriremote", category: "runtime")

/// Record diagnostics through the unified logging system without synchronous file IO.
func rmDebug(_ msg: String) {
    runtimeLogger.debug("\(msg, privacy: .public)")
}

enum RemoteDeviceEvent {
    case added(IOHIDDevice, connectedInterfaceCount: Int)
    case removed(IOHIDDevice, remainingInterfaceCount: Int)
    case reset

    var isConnected: Bool {
        switch self {
        case .added: return true
        case let .removed(_, remainingInterfaceCount): return remainingInterfaceCount > 0
        case .reset: return false
        }
    }
}

/// A2854 exposes seven IOHID interfaces. They share serial/address, while their LocationID values
/// differ only in the low interface byte. The registry parent is a final fallback for unusual
/// firmware that omits all three public properties.
func a2854PhysicalIdentity(_ device: IOHIDDevice) -> String {
    if let serial = IOHIDDeviceGetProperty(
        device, kIOHIDSerialNumberKey as CFString
    ) as? String, !serial.isEmpty {
        return "serial:\(serial.lowercased())"
    }
    if let address = IOHIDDeviceGetProperty(
        device, "DeviceAddress" as CFString
    ) as? String, !address.isEmpty {
        return "address:\(address.lowercased())"
    }
    if let location = IOHIDDeviceGetProperty(
        device, kIOHIDLocationIDKey as CFString
    ) as? NSNumber, location.uint64Value != 0 {
        return "location-family:\(location.uint64Value & ~UInt64(0xFF))"
    }
    let service = IOHIDDeviceGetService(device)
    var parent: io_registry_entry_t = 0
    if service != 0,
       IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
        defer { IOObjectRelease(parent) }
        var registryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(parent, &registryID) == KERN_SUCCESS {
            return "registry-parent:\(registryID)"
        }
    }
    return "registry-entry:\(IORegistryEntryGetRegistryEntryIDValue(service))"
}

private func IORegistryEntryGetRegistryEntryIDValue(_ service: io_registry_entry_t) -> UInt64 {
    guard service != 0 else { return 0 }
    var value: UInt64 = 0
    _ = IORegistryEntryGetRegistryEntryID(service, &value)
    return value
}

class RemoteDetector {
    private var manager: IOHIDManager?
    private var deviceCallback: ((RemoteDeviceEvent) -> Void)?
    private var interfaceRegistry = RemoteInterfaceRegistry<IOHIDDevice>()
    private var selectedPhysicalRemoteID: String?
    var onSecondRemoteIgnoredChanged: ((Bool) -> Void)?
    
    private let appleVendorID: Int = 0x004C
    
    private let supportedProductID = 0x0315
    
    init(deviceCallback: @escaping (RemoteDeviceEvent) -> Void) {
        self.deviceCallback = deviceCallback
    }
    
    func startDetection() {
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else {
            rmDebug("⚠️ IOHIDManagerCreate returned nil")
            return
        }

        // A2854 exposes several independent HID-over-GATT interfaces. Per-interface matching keeps
        // all of them visible while still enforcing the exact Apple VID/PID product boundary.
        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: supportedProductID,
             kIOHIDPrimaryUsagePageKey: 0x0C],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: supportedProductID,
             kIOHIDPrimaryUsagePageKey: 0x0D],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: supportedProductID,
             kIOHIDPrimaryUsagePageKey: 0xFF00],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: supportedProductID,
             kIOHIDPrimaryUsagePageKey: 0x01],
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDProductIDKey: supportedProductID,
             kIOHIDPrimaryUsagePageKey: 0x20],
        ]
        // Gen-3 exposes two additional HID-over-GATT report characteristics as usage-page 0x20
        // interfaces (AppleEmbeddedBluetoothInfrared / AppleEmbeddedBluetoothRadio). Keep them in
        // the physical-interface aggregate for correct connection lifetime, but open them
        // non-exclusively. The proven PacketLogger path passively observes the voice stream emitted
        // during a real Siri hold and does not write the old diagnostic Feature 0xFF/0xAF probe.
        //
        // The IR/radio interfaces remain non-exclusive; ordinary control interfaces retain the
        // HyperVibe seize-first behavior in RemoteInputHandler.
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)

        // Check the effective HID-listening capability without requesting a redundant Input
        // Monitoring permission. Accessibility already supplies listening as well as event-posting
        // access; AppDelegate recreates this manager when that capability changes.
        if #available(macOS 10.15, *) {
            let available = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted
            rmDebug("🔐 A2854 HID input access: " + (available ? "available" : "unavailable"))
            guard available else { return }
        }

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(
                format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X) — HID input unavailable",
                openResult
            ))
            return
        }
        rmDebug("🛰 IOHIDManagerOpen success")

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enumerateAllDevices()
        }
    }
    
    func stopDetection() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        interfaceRegistry.removeAll()
        selectedPhysicalRemoteID = nil
        onSecondRemoteIgnoredChanged?(false)
        deviceCallback?(.reset)
    }
    
    private func enumerateAllDevices() {
        guard let manager = manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }
        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let v = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            rmDebug(String(format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                           v, p, pup, pu, n))
            if isSiriRemote(device) {
                handleDeviceAdded(device)
            }
        }
    }
    
    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              vendorID == appleVendorID else { return false }
        
        return IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            == supportedProductID
    }

    private func physicalRemoteID(_ device: IOHIDDevice) -> String {
        a2854PhysicalIdentity(device)
    }
    
    func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }

        // IOHIDManager is scheduled on the main run loop, but keep the mutation explicitly on main
        // for callers such as tests/enumeration that may invoke this method from another thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.manager != nil else { return }
            let physicalID = self.physicalRemoteID(device)
            if let selected = self.selectedPhysicalRemoteID, selected != physicalID {
                rmDebug("🛰 ignoring second A2854 physical remote id=\(physicalID)")
                self.onSecondRemoteIgnoredChanged?(true)
                return
            }
            if self.selectedPhysicalRemoteID == nil { self.selectedPhysicalRemoteID = physicalID }
            guard self.interfaceRegistry.add(device) else { return }
            let vendorID = IOHIDDeviceGetProperty(
                device, kIOHIDVendorIDKey as CFString
            ) as? Int ?? 0
            let productID = IOHIDDeviceGetProperty(
                device, kIOHIDProductIDKey as CFString
            ) as? Int ?? 0
            let productName = IOHIDDeviceGetProperty(
                device, kIOHIDProductKey as CFString
            ) as? String ?? "Unknown"
            if self.interfaceRegistry.count == 1 {
                rmDebug("✅ Siri Remote connected: \(productName) "
                    + "(Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), "
                    + "Product: 0x\(String(productID, radix: 16, uppercase: true)))")
            }
            rmDebug("🛰 interface connected name=\(productName) activeInterfaces=\(self.interfaceRegistry.count)")
            self.deviceCallback?(.added(
                device, connectedInterfaceCount: self.interfaceRegistry.count
            ))
        }
    }
    
    func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isSiriRemote(device) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.interfaceRegistry.remove(device) else { return }
            let remaining = self.interfaceRegistry.count
            let productName = IOHIDDeviceGetProperty(
                device, kIOHIDProductKey as CFString
            ) as? String ?? "Unknown"
            rmDebug("🛰 interface disconnected name=\(productName) activeInterfaces=\(remaining)")
            self.deviceCallback?(.removed(device, remainingInterfaceCount: remaining))
            if remaining == 0 {
                self.selectedPhysicalRemoteID = nil
                self.onSecondRemoteIgnoredChanged?(false)
                rmDebug("❌ Siri Remote disconnected: \(productName)")
            }
        }
    }
}

// C callbacks
private func deviceAddedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceAdded(device)
}

private func deviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handleDeviceRemoved(device)
}
