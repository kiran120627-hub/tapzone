import Foundation
import IOKit
import IOKit.hid

/// Seconds on the mach clock (same clock as HID report timestamps).
enum Clock {
    static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    static func now() -> Double { Double(mach_absolute_time()) * scale }
}

/// Streams the MacBook's built-in motion sensor (accelerometer + gyroscope) and lid angle.
///
/// The sensors are exposed as vendor HID services (`AppleSPUHIDDevice`, usage page 0xFF00:
/// usage 3 = accelerometer, 9 = gyroscope; usage page 0x20 / 0x8A = lid angle). They only report
/// once their `AppleSPUHIDDriver` is told to, so `start()` switches reporting on first.
final class MotionSensor {
    enum Channel { case accel, gyro }

    /// Called on the sensor thread: channel, timestamp (s), x/y/z (g or deg/s).
    var onSample: ((Channel, Double, SIMD3<Double>) -> Void)?

    private(set) var lidAngle: Int?
    private(set) var hasAccel = false
    private(set) var hasGyro = false
    private var thread: Thread?
    private var devices: [(IOHIDDevice, UnsafeMutablePointer<UInt8>)] = []
    private var lid: IOHIDDevice?

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "tapzone.sensor"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    private func run() {
        enableReporting()
        openDevices()
        // Poll the lid angle while the run loop delivers IMU reports.
        while !Thread.current.isCancelled {
            pollLid()
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            // The sensor hub is shared: another program can switch reporting off. Switch it back on.
            if !paused && Clock.now() - lastSample > 2 {
                enableReporting()
                lastSample = Clock.now()
            }
        }
    }

    private func services(_ cls: String) -> [io_service_t] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [io_service_t] = []
        while case let s = IOIteratorNext(iter), s != 0 { out.append(s) }
        return out
    }

    private func intProperty(_ s: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    /// The two drivers behind the accelerometer and gyroscope (and nothing else on the sensor hub).
    private func motionDrivers() -> [io_service_t] {
        services("AppleSPUHIDDriver").filter { s in
            let keep = intProperty(s, "PrimaryUsagePage") == 0xFF00 && [3, 9].contains(intProperty(s, "PrimaryUsage") ?? 0)
            if !keep { IOObjectRelease(s) }
            return keep
        }
    }

    /// Requested report interval in microseconds; the hardware tops out near 800 Hz.
    private(set) var intervalMicros = 1000

    private func enableReporting() {
        for s in motionDrivers() {
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", intervalMicros)] {
                IORegistryEntrySetCFProperty(s, key as CFString, value as CFNumber)
            }
            IOObjectRelease(s)
        }
    }

    /// Change the sample rate (Hz). Safe to call from any thread.
    func setRate(_ hz: Double) {
        intervalMicros = Int(1e6 / hz)
        writeInterval(intervalMicros)
    }

    /// Stop streaming (interval 0 tells the sensor hub nobody needs reports). Safe from any thread.
    func pause() { paused = true; writeInterval(0) }

    /// Resume streaming at the last rate set.
    func resume() { paused = false; writeInterval(intervalMicros) }

    private var paused = false
    private var lastSample = Clock.now()   // sensor thread only

    private func writeInterval(_ micros: Int) {
        for s in motionDrivers() {
            IORegistryEntrySetCFProperty(s, "ReportInterval" as CFString, micros as CFNumber)
            IOObjectRelease(s)
        }
    }

    private func openDevices() {
        for s in services("AppleSPUHIDDevice") {
            defer { IOObjectRelease(s) }
            let page = intProperty(s, "PrimaryUsagePage"), usage = intProperty(s, "PrimaryUsage")
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, s) else { continue }
            if page == 0x20 && usage == 0x8A {
                if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess { lid = dev }
                continue
            }
            guard page == 0xFF00, usage == 3 || usage == 9 else { continue }
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            let size = 64
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOHIDReportWithTimeStampCallback = usage == 3 ? MotionSensor.accelReport : MotionSensor.gyroReport
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, buf, size, callback, ctx)
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            devices.append((dev, buf))
            if usage == 3 { hasAccel = true } else { hasGyro = true }
        }
    }

    private func pollLid() {
        guard let lid else { return }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        if IOHIDDeviceGetReport(lid, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 {
            lidAngle = Int(report[1]) | Int(report[2]) << 8
        }
    }

    /// Reports are 22 bytes: little-endian Int32 x/y/z in 16.16 fixed point at offsets 6, 10, 14.
    fileprivate func handle(_ channel: Channel, _ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex, _ stamp: UInt64) {
        guard length >= 18 else { return }
        func axis(_ o: Int) -> Double {
            let raw = UInt32(report[o]) | UInt32(report[o + 1]) << 8 | UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24
            return Double(Int32(bitPattern: raw)) / 65536
        }
        lastSample = Clock.now()
        onSample?(channel, Double(stamp) * Clock.scale, SIMD3(axis(6), axis(10), axis(14)))
    }

    private static let accelReport: IOHIDReportWithTimeStampCallback = { ctx, _, _, _, _, report, length, stamp in
        Unmanaged<MotionSensor>.fromOpaque(ctx!).takeUnretainedValue().handle(.accel, report, length, stamp)
    }
    private static let gyroReport: IOHIDReportWithTimeStampCallback = { ctx, _, _, _, _, report, length, stamp in
        Unmanaged<MotionSensor>.fromOpaque(ctx!).takeUnretainedValue().handle(.gyro, report, length, stamp)
    }
}
