import Foundation
import Darwin

// Do not call waitUntilExit on a network child during recovery. Even after a
// signal the UI service must have a deadline and retain an unresponsive child.
enum ProcessShutdown {
    private static func wait(_ process: Process, seconds: Int) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    static func stop(_ process: Process) -> Bool {
        if wait(process, seconds: 2) { return true }
        process.terminate()
        if wait(process, seconds: 1) { return true }
        kill(process.processIdentifier, SIGKILL)
        return wait(process, seconds: 1)
    }
}
