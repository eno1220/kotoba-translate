import Combine
import Darwin
import Foundation
import IOKit.ps

/// System snapshots do not start Python or read user translation content.
struct ServerResources {
    var availableBytes: UInt64
    var onACPower: Bool
    var lowPower: Bool
    var hot: Bool
    var memoryPressure: Bool = false

    static func current() -> Self {
        var info = vm_statistics64()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        // Reclaimable inactive pages are included; compressed and wired pages are not.
        let pages = UInt64(info.free_count) + UInt64(info.inactive_count)
        let power = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = power.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let process = ProcessInfo.processInfo
        var pressureLevel: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureKnown = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0) == 0
        return Self(availableBytes: result == KERN_SUCCESS ? pages * UInt64(vm_kernel_page_size) : 0,
                    onACPower: source == kIOPSACPowerValue, lowPower: process.isLowPowerModeEnabled,
                    hot: process.thermalState == .serious || process.thermalState == .critical,
                    memoryPressure: pressureKnown && pressureLevel != 1)
    }
}

/// Bound the burst in memory. Each active request owns a separate private worker,
/// so a disconnect can terminate just that worker, including during model loading.
@MainActor
final class ServerInferencePool: ObservableObject {
    @Published var maxConcurrency: Int { didSet {
        UserDefaults.standard.set(maxConcurrency, forKey: "serverConcurrency")
        pump()
    } }
    @Published var allowBattery: Bool { didSet {
        UserDefaults.standard.set(allowBattery, forKey: "serverAllowBattery")
        pump()
    } }
    @Published var reserveGB: Int { didSet {
        UserDefaults.standard.set(reserveGB, forKey: "serverReserveGB")
        pump()
    } }
    @Published private(set) var activeCount = 0
    @Published private(set) var waitingCount = 0
    @Published private(set) var loadedCount = 0
    @Published private(set) var resources: ServerResources
    @Published private(set) var reason = "需要に応じて追加します"
    static let queueLimit = 32
    static let surplusIdleSeconds = 30

    private final class Slot {
        let translator: Translator
        var assigned = false
        var model = ""
        var budget: Budget?
        var lastUsed = Date()
        init(_ translator: Translator) { self.translator = translator }
    }
    struct Budget {
        var weights: UInt64
        var cache: UInt64
        var coldBytes: UInt64 { weights + cache + 1024 * 1024 * 1024 }

        static func read(_ model: String) -> Self? {
            let url = URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let layers = config["num_hidden_layers"] as? Int, (1...512).contains(layers),
                  let heads = config["num_key_value_heads"] as? Int, (1...512).contains(heads),
                  let dimension = config["head_dim"] as? Int, (1...1024).contains(dimension),
                  let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
            let shards = files.filter { $0.pathExtension == "safetensors" }
            guard !shards.isEmpty else { return nil }
            var weights: UInt64 = 0
            for file in shards {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
                weights += UInt64(size)
            }
            // Reserve the full 32K KV cache in BF16 (K + V), even for local-attention
            // layers. This deliberately overestimates short browser fragments.
            let cache = UInt64(layers) * UInt64(heads) * UInt64(dimension) * 32768 * 4
            return Self(weights: weights + weights / 4, cache: cache)
        }
    }
    private struct Waiting {
        let id: UUID
        let model: String
        let budget: Budget?
        let continuation: CheckedContinuation<Slot, Error>
    }
    private let preferences: Preferences
    private var slots: [Slot]
    private var waiting: [Waiting] = []
    private var monitor: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pressure = false
    private var accepting = false
    private let readResources: () -> ServerResources
    private let readBudget: @Sendable (String) -> Budget?

    init(preferences: Preferences, translator: Translator,
         resources: @escaping () -> ServerResources = ServerResources.current,
         budget: @escaping @Sendable (String) -> Budget? = { Budget.read($0) }) {
        self.preferences = preferences
        slots = [Slot(translator)]
        readResources = resources
        readBudget = budget
        self.resources = resources()
        let defaults = UserDefaults.standard
        maxConcurrency = min(4, max(1, defaults.object(forKey: "serverConcurrency") as? Int ?? 2))
        reserveGB = min(16, max(2, defaults.object(forKey: "serverReserveGB") as? Int ?? 4))
        allowBattery = defaults.bool(forKey: "serverAllowBattery")
    }

    func start() {
        guard !accepting else { return }
        accepting = true
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            self.pressure = !source.data.contains(.normal)
            self.pump()
        }
        pressureSource = source
        source.resume()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.pump()
            }
        }
        pump()
    }

    func stop() {
        accepting = false
        monitor?.cancel()
        monitor = nil
        pressureSource?.cancel()
        pressureSource = nil
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        for slot in slots {
            if slot.assigned || slot.translator.servingAPI { slot.translator.cancel() }
            else if slot !== slots[0] { slot.translator.unload() }
        }
        refreshCounts()
    }

    func cancelActive() {
        for slot in slots where slot.assigned { slot.translator.cancel() }
    }

    func unloadIdle() {
        for slot in slots where !slot.assigned { slot.translator.unload() }
        refreshCounts()
    }

    func translate(_ request: TranslationRequest, delta: @escaping (String) -> Void) async throws -> (String, WorkerEvent) {
        try Task.checkCancellation()
        guard accepting else { throw CancellationError() }
        guard waiting.count < Self.queueLimit else {
            throw APIError(status: 429, message: "待機リクエストが上限の32件に達しました。少し待って再試行してください。")
        }
        let model = request.model
        let readBudget = readBudget
        let budget = await Task.detached(priority: .utility) { readBudget(model) }.value
        try Task.checkCancellation()
        guard accepting else { throw CancellationError() }
        let id = UUID()
        let slot: Slot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiting.count < Self.queueLimit else {
                    continuation.resume(throwing: APIError(status: 429, message: "待機リクエストが上限の32件に達しました。"))
                    return
                }
                waiting.append(Waiting(id: id, model: model, budget: budget, continuation: continuation))
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        }
        defer {
            slot.assigned = false
            slot.lastUsed = Date()
            pump()
        }
        try Task.checkCancellation()
        guard accepting else { throw CancellationError() }
        return try await slot.translator.translateAPI(request, delta: delta)
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        pump()
    }

    private func refreshCounts() {
        activeCount = slots.filter(\.assigned).count
        waitingCount = waiting.count
        loadedCount = slots.filter { $0.translator.loaded || $0.assigned }.count
    }

    private func pump() {
        resources = readResources()
        resources.memoryPressure = resources.memoryPressure || pressure
        guard accepting else { refreshCounts(); return }
        let limit: Int
        if resources.memoryPressure { limit = 1; reason = "メモリプレッシャーのため1並列" }
        else if resources.lowPower { limit = 1; reason = "低電力モードのため1並列" }
        else if resources.hot { limit = 1; reason = "本体が高温のため1並列" }
        else if !resources.onACPower && !allowBattery { limit = 1; reason = "バッテリー駆動のため1並列" }
        else { limit = min(4, max(1, maxConcurrency)); reason = limit == 1 ? "設定により1並列" : "需要に応じて追加します" }

        // Finish active requests normally when a power/thermal limit falls.
        // Idle surplus workers are terminated immediately under pressure.
        for slot in slots.dropFirst() where !slot.assigned && !slot.translator.busy {
            if limit == 1 || resources.memoryPressure || Date().timeIntervalSince(slot.lastUsed) >= Double(Self.surplusIdleSeconds) {
                slot.translator.unload()
            }
        }
        let primary = slots[0]
        slots.removeAll { $0 !== primary && !$0.assigned && !$0.translator.loaded && !$0.translator.busy }
        if resources.memoryPressure && !slots[0].assigned { slots[0].translator.unload() }
        // The editor owns the shared worker outside this pool. Wait for it rather
        // than expanding against an untracked model/cache allocation.
        if primary.translator.busy && !primary.assigned {
            reason = "翻訳画面の処理完了を待機"
            refreshCounts()
            return
        }

        while let next = waiting.first {
            let occupied = slots.filter { $0.assigned || $0.translator.busy }.count
            guard occupied < limit else { break }
            // Reuse the shared worker first; no additional process for ordinary traffic.
            var candidate: Slot?
            if !primary.assigned && !primary.translator.busy { candidate = primary }
            if candidate == nil { candidate = slots.first { !$0.assigned && !$0.translator.busy && $0.translator.loadedModelPath == next.model } }
            if candidate == nil { candidate = slots.first { !$0.assigned && !$0.translator.busy } }
            if occupied > 0 {
                // Only one cold load at a time. The next expansion uses a fresh OS snapshot.
                guard slots.filter({ $0.assigned }).allSatisfy({ $0.translator.loadedModelPath == $0.model }) else {
                    reason = "モデル読み込み完了後に並列数を再判定"; break
                }
                guard let budget = next.budget else { reason = "モデルのメモリ必要量を確認できないため追加を待機"; break }
                let warm = candidate?.translator.loadedModelPath == next.model
                let required = warm ? budget.cache : budget.coldBytes
                let reserved = slots.filter(\.assigned).reduce(UInt64(0)) { $0 + ($1.budget?.cache ?? 0) }
                let headroom = UInt64(min(16, max(2, reserveGB))) * 1024 * 1024 * 1024
                guard resources.availableBytes > headroom + reserved + required else {
                    reason = "メモリの余裕を確保するため追加を待機"; break
                }
            }
            if candidate == nil {
                guard slots.count < limit else { break }
                let slot = Slot(Translator(preferences: preferences, idleSecondsOverride: Self.surplusIdleSeconds))
                slots.append(slot)
                candidate = slot
            }
            guard let slot = candidate else { break }
            slot.assigned = true
            slot.model = next.model
            slot.budget = next.budget
            waiting.removeFirst().continuation.resume(returning: slot)
        }
        refreshCounts()
    }
}
