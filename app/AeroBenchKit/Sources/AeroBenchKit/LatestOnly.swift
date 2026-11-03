import Foundation

/// Runs one job at a time and only ever the newest waiting one: a submit
/// while a run is going replaces whatever was waiting, which then returns
/// nil. Keeps live previews from piling up behind a slow rebuild.
public actor LatestOnly<Input: Sendable, Output: Sendable> {
    private let run: @Sendable (Input) async throws -> Output
    private var running = false
    private var waiting: (Input, CheckedContinuation<Result<Output, Error>?, Never>)?

    public init(run: @escaping @Sendable (Input) async throws -> Output) {
        self.run = run
    }

    public func submit(_ input: Input) async -> Result<Output, Error>? {
        if running {
            return await withCheckedContinuation { c in
                waiting?.1.resume(returning: nil)
                waiting = (input, c)
            }
        }
        running = true
        let mine = await attempt(input)
        while let (next, c) = waiting {
            waiting = nil
            c.resume(returning: await attempt(next))
        }
        running = false
        return mine
    }

    private func attempt(_ input: Input) async -> Result<Output, Error> {
        do { return .success(try await run(input)) } catch { return .failure(error) }
    }
}
