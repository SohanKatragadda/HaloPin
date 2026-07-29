import Foundation

final class CaptureActivityTracker: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let generationStartSequence: UInt64
    }

    private struct Waiter {
        let generation: UInt64
        let targetSequence: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var activeStreamID: ObjectIdentifier?
        var generation: UInt64 = 0
        var sequence: UInt64 = 0
        var generationStartSequence: UInt64 = 0
        var lastHeartbeat: ContinuousClock.Instant?
        var monitoringEnabled = false
        var health: CaptureHealth = .stopped
        var waiters: [UUID: Waiter] = [:]
        var cancelledWaiters: Set<UUID> = []
    }

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var state = State()

    @discardableResult
    func begin(streamID: ObjectIdentifier) -> UInt64 {
        let continuations: [CheckedContinuation<Bool, Never>]
        let generation: UInt64
        lock.lock()
        state.generation &+= 1
        generation = state.generation
        state.activeStreamID = streamID
        state.generationStartSequence = state.sequence
        state.lastHeartbeat = nil
        state.health = .stopped
        state.cancelledWaiters.removeAll(keepingCapacity: true)
        continuations = state.waiters.values.map(\.continuation)
        state.waiters.removeAll(keepingCapacity: true)
        lock.unlock()
        continuations.forEach { $0.resume(returning: false) }
        return generation
    }

    @discardableResult
    func invalidate() -> CaptureHealth? {
        let continuations: [CheckedContinuation<Bool, Never>]
        let transition: CaptureHealth?
        lock.lock()
        state.generation &+= 1
        state.activeStreamID = nil
        state.lastHeartbeat = nil
        state.monitoringEnabled = false
        transition = state.health == .stopped ? nil : .stopped
        state.health = .stopped
        state.cancelledWaiters.removeAll(keepingCapacity: true)
        continuations = state.waiters.values.map(\.continuation)
        state.waiters.removeAll(keepingCapacity: true)
        lock.unlock()
        continuations.forEach { $0.resume(returning: false) }
        return transition
    }

    func isCurrent(streamID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.activeStreamID == streamID
    }

    func process(
        streamID: ObjectIdentifier,
        disposition: CaptureFrameDisposition,
        render: () -> Void
    ) -> CaptureHealth? {
        var continuations: [CheckedContinuation<Bool, Never>] = []
        var transition: CaptureHealth?

        lock.lock()
        guard state.activeStreamID == streamID else {
            lock.unlock()
            return nil
        }

        switch disposition {
        case .complete:
            render()
            state.sequence &+= 1
            state.lastHeartbeat = clock.now
        case .heartbeatOnly:
            state.lastHeartbeat = clock.now
        case .ignored:
            lock.unlock()
            return nil
        }

        if state.monitoringEnabled, state.health != .healthy {
            state.health = .healthy
            transition = .healthy
        }

        if disposition == .complete {
            let generation = state.generation
            let sequence = state.sequence
            let satisfied = state.waiters.filter {
                $0.value.generation == generation
                    && $0.value.targetSequence <= sequence
            }
            for (identifier, waiter) in satisfied {
                state.waiters.removeValue(forKey: identifier)
                continuations.append(waiter.continuation)
            }
        }
        lock.unlock()

        continuations.forEach { $0.resume(returning: true) }
        return transition
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            generation: state.generation,
            sequence: state.sequence,
            generationStartSequence: state.generationStartSequence
        )
    }

    func setMonitoring(enabled: Bool) -> CaptureHealth? {
        lock.lock()
        defer { lock.unlock() }
        state.monitoringEnabled = enabled
        let next: CaptureHealth
        if enabled, state.activeStreamID != nil, state.lastHeartbeat != nil {
            next = .healthy
        } else {
            next = .stopped
        }
        guard next != state.health else { return nil }
        state.health = next
        return next
    }

    func remainingUntilStall(timeout: Duration) -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        guard state.monitoringEnabled, state.activeStreamID != nil else {
            return nil
        }
        guard let lastHeartbeat = state.lastHeartbeat else {
            return .zero
        }
        let elapsed = lastHeartbeat.duration(to: clock.now)
        return elapsed >= timeout ? .zero : timeout - elapsed
    }

    func markStalledIfNeeded(timeout: Duration) -> CaptureHealth? {
        lock.lock()
        defer { lock.unlock() }
        guard state.monitoringEnabled, state.activeStreamID != nil else {
            return nil
        }
        let isStalled: Bool
        if let lastHeartbeat = state.lastHeartbeat {
            isStalled = lastHeartbeat.duration(to: clock.now) >= timeout
        } else {
            isStalled = true
        }
        guard isStalled, state.health != .stalled else { return nil }
        state.health = .stalled
        return .stalled
    }

    func waitForAdvance(
        after baseline: UInt64,
        generation: UInt64,
        count: UInt64,
        timeout: Duration
    ) async -> Bool {
        let target = baseline &+ count
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForSequence(
                    target,
                    generation: generation
                )
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func waitForSequence(
        _ target: UInt64,
        generation: UInt64
    ) async -> Bool {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(
                    identifier: identifier,
                    generation: generation,
                    target: target,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancelWaiter(identifier)
        }
    }

    private func register(
        identifier: UUID,
        generation: UInt64,
        target: UInt64,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        if state.cancelledWaiters.remove(identifier) != nil {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        guard state.activeStreamID != nil, state.generation == generation else {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        guard state.sequence < target else {
            lock.unlock()
            continuation.resume(returning: true)
            return
        }
        state.waiters[identifier] = Waiter(
            generation: generation,
            targetSequence: target,
            continuation: continuation
        )
        lock.unlock()
    }

    private func cancelWaiter(_ identifier: UUID) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        if let waiter = state.waiters.removeValue(forKey: identifier) {
            continuation = waiter.continuation
        } else {
            state.cancelledWaiters.insert(identifier)
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: false)
    }
}
