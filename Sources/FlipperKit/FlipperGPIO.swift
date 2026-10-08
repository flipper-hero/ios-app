#if !FLIPPERHERO_STORE
import Foundation
import FlipperProto

/// The GPIO pins the Flipper exposes on its header, as used by the firmware's RPC.
public enum FlipperGPIOPin: String, Sendable, CaseIterable {
    case pc0, pc1, pc3, pb2, pb3, pa4, pa6, pa7

    var proto: PBGpio_GpioPin {
        switch self {
        case .pc0: .pc0
        case .pc1: .pc1
        case .pc3: .pc3
        case .pb2: .pb2
        case .pb3: .pb3
        case .pa4: .pa4
        case .pa6: .pa6
        case .pa7: .pa7
        }
    }
}

extension FlipperRPCClient {
    /// Puts a pin in input or output mode; input pins can select a pull resistor.
    public func gpioSetMode(pin: FlipperGPIOPin, output: Bool, pullUp: Bool? = nil) async throws {
        if output {
            var request = PBGpio_SetPinMode()
            request.pin = pin.proto
            request.mode = .output
            _ = try await call(.gpioSetPinMode(request))
        } else {
            var request = PBGpio_SetPinMode()
            request.pin = pin.proto
            request.mode = .input
            _ = try await call(.gpioSetPinMode(request))
            var pull = PBGpio_SetInputPull()
            pull.pin = pin.proto
            pull.pullMode = pullUp == true ? .up : pullUp == false ? .down : .no
            _ = try await call(.gpioSetInputPull(pull))
        }
    }

    /// Reads a pin set to input mode: true means the level is high.
    public func gpioRead(pin: FlipperGPIOPin) async throws -> Bool {
        var request = PBGpio_ReadPin()
        request.pin = pin.proto
        let parts = try await call(.gpioReadPin(request))
        guard case .gpioReadPinResponse(let response)? = parts.first?.content else {
            throw FlipperError.unexpectedResponse
        }
        return response.value != 0
    }

    /// Drives a pin set to output mode: true means the level goes high.
    public func gpioWrite(pin: FlipperGPIOPin, level: Bool) async throws {
        var request = PBGpio_WritePin()
        request.pin = pin.proto
        request.value = level ? 1 : 0
        _ = try await call(.gpioWritePin(request))
    }
}
#endif
