import Foundation
@preconcurrency import XPC

// The service only starts its bundled bridge, with validated desk settings.
private final class BridgeSession: @unchecked Sendable {
    var child: Process?
}

func runManagedBridge() -> Never {
    let queue = DispatchQueue(label: "com.control24.bridge.session")
    let session = BridgeSession()
    let listener = xpc_connection_create_mach_service(
        "com.control24.bridge", queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
    )
    xpc_connection_set_event_handler(listener) { event in
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        let peer = event
        let requirement = "anchor apple generic and identifier \"com.control24.lab\" and certificate leaf[subject.OU] = \"9X676ZSAQX\""
        guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
            xpc_connection_cancel(peer)
            return
        }
        let client = BridgeSession()
        xpc_connection_set_target_queue(peer, queue)
        xpc_connection_set_event_handler(peer) { request in
            if xpc_get_type(request) == XPC_TYPE_ERROR {
                if let child = client.child, child.isRunning { child.terminate() }
                return
            }
            guard xpc_get_type(request) == XPC_TYPE_DICTIONARY,
                  let reply = xpc_dictionary_create_reply(request) else { return }
            defer { xpc_connection_send_message(peer, reply) }
            guard client.child?.isRunning != true, session.child?.isRunning != true,
                  let token = xpc_dictionary_get_string(request, "token"),
                  UUID(uuidString: String(cString: token)) != nil,
                  let device = xpc_dictionary_get_string(request, "interface"),
                  let address = xpc_dictionary_get_string(request, "mac") else {
                xpc_dictionary_set_string(reply, "error", "Bridge busy or invalid settings")
                return
            }
            let interface = String(cString: device)
            let mac = String(cString: address)
            guard interface.range(of: "^en[0-9]{1,3}$", options: .regularExpression) != nil,
                  mac.range(of: "^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", options: .regularExpression) != nil else {
                xpc_dictionary_set_string(reply, "error", "Invalid network interface or console address")
                return
            }
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--interface", interface, "--port", "9127", "--token", String(cString: token), "--mac", mac, "--active"]
            do {
                try child.run()
                client.child = child
                session.child = child
            } catch {
                xpc_dictionary_set_string(reply, "error", error.localizedDescription)
            }
        }
        xpc_connection_resume(peer)
    }
    xpc_connection_resume(listener)
    dispatchMain()
}
