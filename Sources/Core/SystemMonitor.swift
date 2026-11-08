import Foundation
import Metal
import QuartzCore
import SwiftUI
import os

/// GPU 가 실제로 돌아간 시간을 모은다.
///
/// iOS 에는 GPU 사용률 API 가 없다. 하지만 우리가 쏘는 명령 버퍼마다
/// `gpuStartTime` / `gpuEndTime` 을 알려주므로, 측정 구간 동안 GPU 가 실제로
/// 일한 시간을 벽시계 시간으로 나누면 '우리 때문에 GPU 가 바빴던 비율'이 나온다.
/// 추정이 아니라 실측이다.
final class GPUClock: @unchecked Sendable {
    static let shared = GPUClock()
    private let lock = NSLock()
    private var busy: Double = 0
    private var totalBusy: Double = 0
    private var buffers = 0

    func add(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds < 30 else { return }
        lock.lock()
        busy += seconds
        totalBusy += seconds
        buffers += 1
        lock.unlock()
    }

    func drain() -> Double {
        lock.lock(); defer { lock.unlock() }
        let value = busy
        busy = 0
        return value
    }

    var stats: (seconds: Double, buffers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (totalBusy, buffers)
    }

    func resetTotals() {
        lock.lock(); totalBusy = 0; buffers = 0; lock.unlock()
    }
}

/// CPU · GPU · 메모리를 4Hz 로 샘플링해서 그래프용 링버퍼에 쌓는다.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    static let capacity = 90          // 90샘플 = 22.5초

    @Published private(set) var cpu: [Double] = []      // 0 ... 1 (전 코어 기준)
    @Published private(set) var gpu: [Double] = []      // 0 ... 1
    @Published private(set) var ram: [Double] = []      // 0 ... 1 (앱 한도 기준)

    @Published private(set) var cpuNow: Double = 0
    @Published private(set) var cpuCores: Double = 0    // 바쁜 코어 수
    @Published private(set) var gpuNow: Double = 0
    @Published private(set) var ramBytes: UInt64 = 0
    @Published private(set) var ramLimit: UInt64 = 0
    @Published private(set) var ramPeak: UInt64 = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private var lastSample = CACurrentMediaTime()
    let coreCount = max(ProcessInfo.processInfo.activeProcessorCount, 1)

    private init() {}

    func start() {
        guard timer == nil else { return }
        isRunning = true
        lastSample = CACurrentMediaTime()
        _ = GPUClock.shared.drain()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func reset() {
        cpu.removeAll(); gpu.removeAll(); ram.removeAll()
        ramPeak = 0
        GPUClock.shared.resetTotals()
    }

    private func sample() {
        let now = CACurrentMediaTime()
        let dt = max(now - lastSample, 0.016)
        lastSample = now

        let cores = SystemMonitor.processCPUCores()
        cpuCores = cores
        cpuNow = min(cores / Double(coreCount), 1)

        let busy = GPUClock.shared.drain()
        gpuNow = min(busy / dt, 1)

        let bytes = SystemMonitor.footprint()
        ramBytes = bytes
        ramPeak = max(ramPeak, bytes)
        let limit = SystemMonitor.memoryLimit(current: bytes)
        ramLimit = limit
        let ratio = limit > 0 ? Double(bytes) / Double(limit) : 0

        thermal = ProcessInfo.processInfo.thermalState

        push(&cpu, cpuNow)
        push(&gpu, gpuNow)
        push(&ram, min(ratio, 1))
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value.isFinite ? value : 0)
        if array.count > SystemMonitor.capacity { array.removeFirst(array.count - SystemMonitor.capacity) }
    }

    // MARK: - 측정

    /// 이 앱이 쓰고 있는 CPU — '바쁜 코어 수' 단위 (2.0 이면 두 코어를 꽉 쓰는 중)
    nonisolated static func processCPUCores() -> Double {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(list))),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        var total: Double = 0
        for index in 0..<Int(count) {
            var info = thread_basic_info_data_t()
            var size = infoCount
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO),
                            UnsafeMutablePointer<integer_t>(OpaquePointer(pointer)), &size)
            }
            guard result == KERN_SUCCESS else { continue }
            if info.flags & 0x1 != 0 { continue }           // TH_FLAGS_IDLE
            total += Double(info.cpu_usage) / 1000.0        // TH_USAGE_SCALE
        }
        return total
    }

    /// 이 앱의 실제 메모리 사용량 (iOS 가 강제 종료 판단에 쓰는 바로 그 값)
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO),
                      UnsafeMutablePointer<integer_t>(OpaquePointer(pointer)), &count)
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// 앱이 쓸 수 있는 메모리 상한 (남은 양 + 지금 쓰는 양)
    nonisolated static func memoryLimit(current: UInt64) -> UInt64 {
        let available = UInt64(max(os_proc_available_memory(), 0))
        if available > 0 { return current + available }
        return ProcessInfo.processInfo.physicalMemory / 2
    }

    nonisolated static func text(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "정상"
        case .fair: return "약간 더움"
        case .serious: return "더움 — 성능 제한"
        case .critical: return "과열 — 강제 제한"
        @unknown default: return "알 수 없음"
        }
    }

    var tint: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}
