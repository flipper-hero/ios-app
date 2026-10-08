import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

public struct DiscoveredFlipper: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public init(id: UUID, name: String, rssi: Int) {
        self.id = id; self.name = name; self.rssi = rssi
    }
}

public enum BLEStatus: Sendable, Equatable {
    case unknown, poweredOff, unauthorized, unsupported, ready
}

public enum BLEError: Error, Equatable, CustomStringConvertible {
    case bluetoothUnavailable(BLEStatus)
    case unknownDevice
    case busy
    case timeout
    case pairingFailed
    case pairingInfoRemoved
    case serviceMissing
    case disconnected
    case underlying(String)

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let s): L("Bluetooth is not available (\(String(describing: s)))")
        case .unknownDevice: L("Unknown Flipper, scan again")
        case .busy: L("Another connection attempt is running")
        case .timeout: L("Connecting timed out (pairing PIN entered on the iPhone?)")
        case .pairingFailed: L("Pairing failed. Confirm the PIN shown on the Flipper.")
        case .pairingInfoRemoved: L("The Flipper forgot this iPhone. Remove it in iOS Settings > Bluetooth and pair again.")
        case .serviceMissing: L("This device does not expose the Flipper serial service")
        case .disconnected: L("Flipper disconnected")
        case .underlying(let s): s
        }
    }
}

enum FlipperUUID {
    static let advertised = ["3080", "3081", "3082", "3083"].map { CBUUID(string: $0) }
    static let serial = CBUUID(string: "8FE5B3D5-2E7F-4A98-2A48-7ACC60FE0000")
    static let serialRead = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E61FE0000")
    static let serialWrite = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E62FE0000")
    static let flowControl = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E63FE0000")
}

/// Central manager wrapper: scans for Flippers and opens a transport to one of them.
/// All CoreBluetooth state is confined to `queue`.
public final class FlipperBLE: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public let devices: AsyncStream<[DiscoveredFlipper]>
    public let status: AsyncStream<BLEStatus>

    private let devicesContinuation: AsyncStream<[DiscoveredFlipper]>.Continuation
    private let statusContinuation: AsyncStream<BLEStatus>.Continuation
    private let queue = DispatchQueue(label: "flipper.ble.central")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: DiscoveredFlipper] = [:]
    private var wantsScan = false
    private var seen: Set<UUID> = []
    private var current: BLEFlipperTransport?
    private var connectContinuation: CheckedContinuation<BLEFlipperTransport, Error>?
    private var connectID: UUID?

    public override init() {
        var d: AsyncStream<[DiscoveredFlipper]>.Continuation!
        var s: AsyncStream<BLEStatus>.Continuation!
        devices = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { d = $0 }
        status = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { s = $0 }
        devicesContinuation = d
        statusContinuation = s
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func startScan() {
        queue.async {
            self.wantsScan = true
            self.beginScanIfPossible()
        }
    }

    public func stopScan() {
        queue.async {
            self.wantsScan = false
            self.central.stopScan()
        }
    }

    public func connect(to id: UUID, timeout: Duration = .seconds(60)) async throws -> BLEFlipperTransport {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.central.state == .poweredOn else {
                    continuation.resume(throwing: BLEError.bluetoothUnavailable(Self.map(self.central.state)))
                    return
                }
                // A Flipper paired before can be connected by identifier without scanning,
                // which also works while the app runs in the background (Siri, Shortcuts).
                if self.peripherals[id] == nil,
                   let known = self.central.retrievePeripherals(withIdentifiers: [id]).first {
                    self.peripherals[id] = known
                }
                guard let peripheral = self.peripherals[id] else {
                    continuation.resume(throwing: BLEError.unknownDevice)
                    return
                }
                guard self.connectContinuation == nil else {
                    continuation.resume(throwing: BLEError.busy)
                    return
                }
                self.central.stopScan()
                let transport = BLEFlipperTransport(peripheral: peripheral, central: self.central, queue: self.queue)
                transport.onReady = { [weak self] result in self?.finishConnect(id: id, result) }
                self.current = transport
                self.connectContinuation = continuation
                self.connectID = id
                self.central.connect(peripheral)
                self.queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) { [weak self] in
                    guard let self, self.connectID == id, self.connectContinuation != nil else { return }
                    self.central.cancelPeripheralConnection(peripheral)
                    self.finishConnect(id: id, .failure(BLEError.timeout))
                }
            }
        }
    }

    public func disconnect() {
        queue.async { self.current?.shutdown(error: nil) }
    }

    // MARK: - Internals (queue-confined)

    private func finishConnect(id: UUID, _ result: Result<BLEFlipperTransport, Error>) {
        guard connectID == id, let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectID = nil
        if case .failure = result { current?.shutdown(error: nil) }
        continuation.resume(with: result)
    }

    private func beginScanIfPossible() {
        guard wantsScan, central.state == .poweredOn else { return }
        // A Flipper that is already connected to this phone (e.g. via the official app) stops advertising.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [FlipperUUID.serial]) {
            FlipperLog.log("already connected to system: \(peripheral.name ?? "?")")
            peripherals[peripheral.identifier] = peripheral
            let name = peripheral.name ?? "Flipper"
            found[peripheral.identifier] = DiscoveredFlipper(id: peripheral.identifier, name: name, rssi: 0)
        }
        if !found.isEmpty { devicesContinuation.yield(found.values.sorted { $0.rssi > $1.rssi }) }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private static func map(_ state: CBManagerState) -> BLEStatus {
        switch state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        FlipperLog.log("central state: \(central.state.rawValue)")
        statusContinuation.yield(Self.map(central.state))
        beginScanIfPossible()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        if seen.insert(peripheral.identifier).inserted {
            FlipperLog.log("seen name='\(name)' rssi=\(RSSI) services=\(services.map(\.uuidString)) keys=\(Array(advertisementData.keys))")
        }
        let isFlipper = services.contains(where: FlipperUUID.advertised.contains) || name.hasPrefix("Flipper")
        guard isFlipper else { return }
        if found[peripheral.identifier] == nil { FlipperLog.log("discovered \(name) rssi=\(RSSI) services=\(services.map(\.uuidString))") }
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = DiscoveredFlipper(
            id: peripheral.identifier, name: name.isEmpty ? "Flipper" : name, rssi: RSSI.intValue
        )
        devicesContinuation.yield(found.values.sorted { $0.rssi > $1.rssi })
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        FlipperLog.log("connected, discovering services")
        current?.begin()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        FlipperLog.log("didFailToConnect: \(String(describing: error))")
        finishConnect(id: peripheral.identifier, .failure(BLEError.underlying(error?.localizedDescription ?? "connect failed")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        FlipperLog.log("disconnected: \(String(describing: error))")
        if connectID == peripheral.identifier {
            finishConnect(id: peripheral.identifier, .failure(Self.translate(error) ?? BLEError.disconnected))
        }
        current?.shutdown(error: error)
    }

    static func translate(_ error: Error?) -> BLEError? {
        guard let error else { return nil }
        if let att = error as? CBATTError,
           att.code == .insufficientEncryption || att.code == .insufficientAuthentication {
            return .pairingFailed
        }
        if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation { return .pairingInfoRemoved }
        return .underlying(error.localizedDescription)
    }
}

/// One connected Flipper. Implements the Flipper serial protocol:
/// notify on serialRead, writes to serialWrite, and flow control via the
/// flowControl characteristic (big-endian UInt32 = free buffer bytes on the Flipper).
public final class BLEFlipperTransport: NSObject, FlipperTransport, CBPeripheralDelegate, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    var onReady: ((Result<BLEFlipperTransport, Error>) -> Void)?

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let peripheral: CBPeripheral
    private let central: CBCentralManager
    private let queue: DispatchQueue
    private var serialRead: CBCharacteristic?
    private var serialWrite: CBCharacteristic?
    private var flowControl: CBCharacteristic?
    private var freeSpace = 0
    private var isReady = false
    private var isClosed = false
    private var spaceWaiters: [CheckedContinuation<Int, Error>] = []
    private var writeContinuation: CheckedContinuation<Void, Error>?

    init(peripheral: CBPeripheral, central: CBCentralManager, queue: DispatchQueue) {
        var cont: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { cont = $0 }
        incomingContinuation = cont
        self.peripheral = peripheral
        self.central = central
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }

    // Queue-confined from here.
    func begin() {
        peripheral.discoverServices([FlipperUUID.serial])
    }

    func shutdown(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        let failure: Error = FlipperBLE.translate(error) ?? BLEError.disconnected
        if !isReady { onReady?(.failure(failure)) }
        for waiter in spaceWaiters { waiter.resume(throwing: failure) }
        spaceWaiters.removeAll()
        writeContinuation?.resume(throwing: failure)
        writeContinuation = nil
        incomingContinuation.finish()
        central.cancelPeripheralConnection(peripheral)
    }

    public func close() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.shutdown(error: nil)
                done.resume()
            }
        }
    }

    public func send(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let n = try await reserve(upTo: data.count - offset)
            try await write(data.subdata(in: offset ..< offset + n))
            offset += n
        }
    }

    private func reserve(upTo want: Int) async throws -> Int {
        while true {
            let granted: Int = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                queue.async {
                    if self.isClosed {
                        continuation.resume(throwing: BLEError.disconnected)
                    } else if self.freeSpace > 0 {
                        let mtu = max(20, self.peripheral.maximumWriteValueLength(for: .withoutResponse))
                        let n = min(want, self.freeSpace, mtu)
                        self.freeSpace -= n
                        continuation.resume(returning: n)
                    } else {
                        self.spaceWaiters.append(continuation)
                    }
                }
            }
            if granted > 0 { return granted }
        }
    }

    private func write(_ chunk: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.isClosed, let characteristic = self.serialWrite else {
                    continuation.resume(throwing: BLEError.disconnected)
                    return
                }
                self.writeContinuation = continuation
                self.peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
        }
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        FlipperLog.log("services: \(peripheral.services?.map(\.uuid.uuidString) ?? []) error=\(String(describing: error))")
        if let error { return failSetup(error) }
        guard let service = peripheral.services?.first(where: { $0.uuid == FlipperUUID.serial }) else {
            return failSetup(BLEError.serviceMissing)
        }
        peripheral.discoverCharacteristics(
            [FlipperUUID.serialRead, FlipperUUID.serialWrite, FlipperUUID.flowControl],
            for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { return failSetup(error) }
        FlipperLog.log("characteristics: \(service.characteristics?.map(\.uuid.uuidString) ?? []) error=\(String(describing: error))")
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case FlipperUUID.serialRead: serialRead = c
            case FlipperUUID.serialWrite: serialWrite = c
            case FlipperUUID.flowControl: flowControl = c
            default: break
            }
        }
        guard let serialRead, serialWrite != nil, let flowControl else { return failSetup(BLEError.serviceMissing) }
        // Enabling notifications on these authenticated characteristics triggers iOS pairing.
        peripheral.setNotifyValue(true, for: serialRead)
        peripheral.setNotifyValue(true, for: flowControl)
        peripheral.readValue(for: flowControl)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        FlipperLog.log("notify \(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying) error=\(String(describing: error))")
        if let error { failSetup(error) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if isReady { shutdown(error: error) } else { failSetup(error) }
            return
        }
        guard let value = characteristic.value else { return }
        FlipperLog.log("value \(characteristic.uuid.uuidString) \(value.count) bytes")
        switch characteristic.uuid {
        case FlipperUUID.serialRead:
            incomingContinuation.yield(value)
        case FlipperUUID.flowControl:
            guard value.count >= 4 else { return }
            freeSpace = value.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            FlipperLog.log("flow control free space = \(freeSpace)")
            let waiters = spaceWaiters
            spaceWaiters.removeAll()
            waiters.forEach { $0.resume(returning: 0) }
            if !isReady {
                isReady = true
                onReady?(.success(self))
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == FlipperUUID.serialWrite else { return }
        let continuation = writeContinuation
        writeContinuation = nil
        if let error { continuation?.resume(throwing: FlipperBLE.translate(error) ?? error) } else { continuation?.resume() }
    }

    private func failSetup(_ error: Error) {
        FlipperLog.log("setup failed: \(error)")
        let mapped = (error as? BLEError) ?? FlipperBLE.translate(error) ?? BLEError.underlying(error.localizedDescription)
        if !isReady { onReady?(.failure(mapped)) }
        shutdown(error: nil)
    }
}
#endif
