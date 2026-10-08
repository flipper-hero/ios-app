import Foundation
import FlipperKit

/// The slice of the Flipper API the agent may use. Lets tests run without hardware.
public protocol FlipperControlling: Sendable {
    func deviceInfo() async throws -> [String: String]
    func powerInfo() async throws -> [String: String]
    func storageInfo(path: String) async throws -> FlipperStorageInfo
    func list(path: String) async throws -> [FlipperDirEntry]
    func stat(path: String) async throws -> FlipperDirEntry
    func read(path: String, maxBytes: Int) async throws -> Data
    func write(path: String, data: Data) async throws
    func makeDirectory(path: String) async throws
    func delete(path: String, recursive: Bool) async throws
    func rename(from: String, to: String) async throws
    func startApp(name: String, args: String) async throws
    func transmitOnce(_ app: FlipperApp, path: String, button: String, hold: Duration) async throws
    func emulate(_ app: FlipperApp, path: String) async throws
    func loadBadKeyboardScript(path: String) async throws
    func exitApp() async throws
    func playAlert() async throws
    func setDeviceName(_ name: String) async throws
    func customDeviceName() async throws -> String?
    func captureScreen(timeout: Duration) async throws -> FlipperScreenFrame
    func press(_ key: FlipperKey, long: Bool) async throws
#if !FLIPPERHERO_STORE
    func gpioSetMode(pin: FlipperGPIOPin, output: Bool, pullUp: Bool?) async throws
    func gpioRead(pin: FlipperGPIOPin) async throws -> Bool
    func gpioWrite(pin: FlipperGPIOPin, level: Bool) async throws
    func rawRPC(jsonRequest: String) async throws -> String
#endif
}

extension FlipperRPCClient: FlipperControlling {}
