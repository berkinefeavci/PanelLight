import Foundation

@MainActor final class WriteScheduler {
    private var generation = 0

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        generation += 1
        let scheduledGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.generation == scheduledGeneration else { return }
            action()
        }
    }

    func cancel() { generation += 1 }
}

@MainActor final class LatestWriteQueue {
    private typealias Work = (@escaping @MainActor () -> Void) -> Void
    private var pending: Work?
    private var isWriting = false

    func submit(_ work: @escaping (@escaping @MainActor () -> Void) -> Void) {
        pending = work
        startNext()
    }

    func cancel() { pending = nil }

    private func startNext() {
        guard !isWriting, let work = pending else { return }
        pending = nil
        isWriting = true
        work { [weak self] in
            self?.isWriting = false
            self?.startNext()
        }
    }
}

enum WriteOutcome: Equatable {
    case verified
    case mismatch
    case unreadable
}

func writeOutcome(requested: UInt16, readback: HardwareLevels?) -> WriteOutcome {
    guard let readback else { return .unreadable }
    return readback.current == requested ? .verified : .mismatch
}

// One missed probe (monitor asleep or busy) keeps the row that worked; a second in a row means it is really gone.
func keepsLastKnown(hadHardware: Bool, consecutiveMisses: Int) -> Bool {
    hadHardware && consecutiveMisses < 2
}
