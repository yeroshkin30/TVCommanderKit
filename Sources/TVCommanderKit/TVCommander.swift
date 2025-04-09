//
//  TVCommander.swift
//
//
//  Created by Wilson Desimini on 9/3/23.
//

import Foundation
import Network
import Starscream

public protocol TVCommanderDelegate: AnyObject {
    func tvCommanderDidConnect(_ tvCommander: TVCommander)
    func tvCommanderDidDisconnect(_ tvCommander: TVCommander)
    func tvCommander(_ tvCommander: TVCommander, didUpdateAuthState authStatus: TVAuthStatus)
    func tvCommander(_ tvCommander: TVCommander, didWriteRemoteCommand command: TVRemoteCommand)
    func tvCommander(_ tvCommander: TVCommander, didEncounterError error: TVCommanderError)
    func tvCommander(_ tvCommander: TVCommander, didReceiveToken token: TVAuthToken)
    func tvCommander(_ tvCommander: TVCommander, didReceiveData data: Data)
}

public class TVCommander: WebSocketDelegate {
    public weak var delegate: TVCommanderDelegate?
    private(set) public var tvConfig: TVConnectionConfiguration
    private(set) public var authStatus = TVAuthStatus.none
    private(set) public var isConnected = false
    private let webSocketCreator: TVWebSocketCreator
    private let webSocketHandler = TVWebSocketHandler()
    private var webSocket: WebSocket?
    private var commandQueue = [TVRemoteCommand]()

    init(tvConfig: TVConnectionConfiguration, webSocketCreator: TVWebSocketCreator) {
        self.tvConfig = tvConfig
        self.webSocketCreator = webSocketCreator
        self.webSocketHandler.delegate = self
    }

    public convenience init(tvId: String? = nil, tvIPAddress: String, appName: String, authToken: TVAuthToken? = nil) throws {
        guard appName.isValidAppName else {
            throw TVCommanderError.invalidAppNameEntered
        }
        guard tvIPAddress.isValidIPAddress else {
            throw TVCommanderError.invalidIPAddressEntered
        }
        let tvConfig = TVConnectionConfiguration(
            id: tvId,
            app: appName,
            path: "/api/v2/channels/samsung.remote.control",
            ipAddress: tvIPAddress,
            port: 8002,
            scheme: "wss",
            token: authToken
        )
        self.init(tvConfig: tvConfig, webSocketCreator: TVWebSocketCreator())
    }

    public convenience init(tv: TV, appName: String, authToken: TVAuthToken? = nil) throws {
        guard let ipAddress = tv.ipAddress else { throw TVCommanderError.invalidIPAddressEntered }
        try self.init(tvId: tv.id, tvIPAddress: ipAddress, appName: appName, authToken: authToken)
    }

    // MARK: Establish WebSocket Connection

    /// **NOTE**
    /// make sure any value for `certPinner` inputted here doesn't strongly reference `TVCommander` (will cause a retain cycle if it does)
    public func connectToTV(certPinner: CertificatePinning? = nil) {
        guard !isConnected else {
            handleError(.connectionAlreadyEstablished)
            return
        }
        guard let url = tvConfig.wssURL() else {
            handleError(.urlConstructionFailed)
            return
        }
        webSocket = webSocketCreator.createTVWebSocket(url: url, certPinner: certPinner, delegate: self)
        webSocket?.connect()
    }

    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        webSocketHandler.didReceive(event: event, client: client)
    }

    // MARK: Send Remote Control Commands

    public func sendRemoteCommand(key: TVRemoteCommand.Params.ControlKey) {
        guard checkConnectionAllowed() else { return }

        sendCommandOverWebSocket(createRemoteCommand(key: key))
    }

    /// Send a text as text field input to the TV. Text will replace existing text in TV textfield.
    public func sendText(_ text: String, submit: Bool = false) {
        guard checkConnectionAllowed() else { return }

        let base64Text = Data(text.utf8).base64EncodedString()

        let params = TVRemoteCommand.Params(
            cmd: .textInput(base64Text),
            dataOfCmd: .base64,
            option: false,
            typeOfRemote: submit ? .inputEnd : .inputString
        )
        let command = TVRemoteCommand(method: .control, params: params)
        sendCommandOverWebSocket(command)
    }

    /// Send a mouse move command to the TV. x and y are deltas from the last mouse position.
    public func mouseMove(x: Int, y: Int) {
        guard checkConnectionAllowed() else { return }

        let params: [String: Any] = [
            "Cmd": "Move",
            "TypeOfRemote": "ProcessMouseDevice",
            "Position": [
                "x": x,
                "y": y,
                "Time": dateAsString()

            ]
        ]
        let payload = ["method": "ms.remote.control", "params": params] as [String: Any]
        let endodedParams = try? JSONSerialization.data(withJSONObject: payload)

        let paramsString = String(data: endodedParams!, encoding: .utf8)!

        webSocket?.write(string: paramsString)
    }

    public func fetchApplicationList() {
        guard checkConnectionAllowed() else { return }

        let params: [String: Any] = [
            "data": "",
            "event": "ed.installedApp.get",
            "to": "host"
        ]

        let payload = ["method": "ms.channel.emit", "params": params] as [String: Any]
        let endodedParams = try? JSONSerialization.data(withJSONObject: payload)

        let paramsString = String(data: endodedParams!, encoding: .utf8)!
        webSocket?.write(string: paramsString)
    }

    /// Fetch the app icon for a specific application.
    /// We receive path in response which we receive after `fetchApplicationList()` method.
    public func fetchAppIcon(path: String) {
        guard checkConnectionAllowed() else { return }

        let params: [String: Any] = [
            "data": [
                "iconPath": path
            ],
            "event": "ed.apps.icon",
            "to": "host"
        ]

        let payload = ["method": "ms.channel.emit", "params": params] as [String: Any]
        let endodedParams = try? JSONSerialization.data(withJSONObject: payload)

        let paramsString = String(data: endodedParams!, encoding: .utf8)!

        webSocket?.write(string: paramsString)
    }

    private func checkConnectionAllowed() -> Bool {
        guard isConnected else {
            handleError(.remoteCommandNotConnectedToTV)
            return false
        }
        guard authStatus == .allowed else {
            handleError(.remoteCommandAuthenticationStatusNotAllowed)
            return false
        }

        return true
    }

    private func dateAsString() -> String {
        let timestamp = Date().timeIntervalSince1970
        let timestampString = String(format: "%.6f", timestamp)
        return timestampString
    }

    private func createRemoteCommand(key: TVRemoteCommand.Params.ControlKey) -> TVRemoteCommand {
        let params = TVRemoteCommand.Params(cmd: .click, dataOfCmd: key, option: false, typeOfRemote: .remoteKey)
        return TVRemoteCommand(method: .control, params: params)
    }

    private func sendCommandOverWebSocket(_ command: TVRemoteCommand) {
        commandQueue.append(command)
        if commandQueue.count == 1 {
            sendNextQueuedCommandOverWebSocket()
        }
    }

    private func sendNextQueuedCommandOverWebSocket() {
        guard let command = commandQueue.first else {
            return
        }
        guard let commandStr = try? command.asString() else {
            handleError(.commandConversionToStringFailed)
            return
        }
        webSocket?.write(string: commandStr) { [weak self] in
            guard let self, self.commandQueue.isEmpty == false else { return }
            self.commandQueue.removeFirst()
            self.delegate?.tvCommander(self, didWriteRemoteCommand: command)
            self.sendNextQueuedCommandOverWebSocket()
        }
    }

    // MARK: Send Keyboard Commands

    public func enterText(_ text: String, on keyboard: TVKeyboardLayout) {
        guard isConnected else {
            handleError(.remoteCommandNotConnectedToTV)
            return
        }
        guard authStatus == .allowed else {
            handleError(.remoteCommandAuthenticationStatusNotAllowed)
            return
        }

        let keys = controlKeys(toEnter: text, on: keyboard)
        keys.forEach(sendRemoteCommand(key:))
    }

    private func controlKeys(toEnter text: String, on keyboard: TVKeyboardLayout) -> [TVRemoteCommand.Params.ControlKey] {
        guard !text.isEmpty else { return [] } // Check for empty string, otherwise it will crash on line 145

        let chars = Array(text)
        var moves: [TVRemoteCommand.Params.ControlKey] = [.enter]
        for i in 0..<(chars.count - 1) {
            let currentChar = String(chars[i])
            let nextChar = String(chars[i + 1])
            if let movesToNext = controlKeys(toMoveFrom: currentChar, to: nextChar, on: keyboard) {
                moves.append(contentsOf: movesToNext)
                moves.append(.enter)
            } else {
                delegate?.tvCommander(self, didEncounterError: .keyboardCharNotFound(nextChar))
            }
        }
        return moves
    }

    private func controlKeys(toMoveFrom char1: String, to char2: String, on keyboard: TVKeyboardLayout) -> [TVRemoteCommand.Params.ControlKey]? {
        guard let (startRow, startCol) = coordinates(of: char1, on: keyboard),
              let (endRow, endCol) = coordinates(of: char2, on: keyboard) else {
            return nil
        }
        let rowDiff = endRow - startRow
        let colDiff = endCol - startCol
        var moves: [TVRemoteCommand.Params.ControlKey] = []
        if rowDiff > 0 {
            moves += Array(repeating: .down, count: rowDiff)
        } else if rowDiff < 0 {
            moves += Array(repeating: .up, count: abs(rowDiff))
        }
        if colDiff > 0 {
            moves += Array(repeating: .right, count: colDiff)
        } else if colDiff < 0 {
            moves += Array(repeating: .left, count: abs(colDiff))
        }
        return moves
    }

    private func coordinates(of char: String, on keyboard: TVKeyboardLayout) -> (Int, Int)? {
        for (row, rowChars) in keyboard.enumerated() {
            if let colIndex = rowChars.firstIndex(of: char) {
                return (row, colIndex)
            }
        }
        return nil
    }

    // MARK: Disconnect WebSocket Connection

    public func disconnectFromTV() {
        webSocket?.disconnect()
    }

    // MARK: Handler Errors

    private func handleError(_ error: TVCommanderError) {
        delegate?.tvCommander(self, didEncounterError: error)
    }

    // MARK: Wake on LAN

    public static func wakeOnLAN(
        device: TVWakeOnLANDevice,
        queue: DispatchQueue = .global(),
        completion: @escaping (TVCommanderError?) -> Void
    ) {
        let connection = NWConnection(
            host: .init(device.broadcast),
            port: .init(rawValue: device.port)!,
            using: .udp
        )
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                connection.send(
                    content: .magicPacket(from: device),
                    completion: .contentProcessed({
                        connection.cancel()
                        completion($0.flatMap(TVCommanderError.wakeOnLANProcessingError))
                    })
                )
            case .failed(let error):
                completion(.wakeOnLANConnectionError(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

// MARK: TVWebSocketHandlerDelegate

extension TVCommander: TVWebSocketHandlerDelegate {
    func webSocketDidConnect() {
        isConnected = true
        delegate?.tvCommanderDidConnect(self)
    }
    
    func webSocketDidDisconnect() {
        isConnected = false
        authStatus = .none
        webSocket = nil
        delegate?.tvCommanderDidDisconnect(self)
    }
    
    func webSocketDidReadAuthStatus(_ authStatus: TVAuthStatus) {
        self.authStatus = authStatus
        delegate?.tvCommander(self, didUpdateAuthState: authStatus)
    }
    
    func webSocketDidReadAuthToken(_ authToken: TVAuthToken) {
        tvConfig.token = authToken
        delegate?.tvCommander(self, didReceiveToken: authToken)
    }
    
    func webSocketError(_ error: TVCommanderError) {
        delegate?.tvCommander(self, didEncounterError: error)
    }

    func webSocketDataReceived(_ data: Data) {
        delegate?.tvCommander(self, didReceiveData: data)
        print("Data received: \(data)")
    }
}
