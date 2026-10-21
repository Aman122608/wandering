import Darwin
import Foundation

/// Finds the developer tunnel by asking the network, not by assuming an address.
///
/// iOS 26 changed the addresses the on-device developer daemon listens on, and a
/// packet-tunnel app (LocalDevVPN, StosVPN) picks its own subnet, so the only
/// reliable approach is: enumerate tunnel interfaces, derive the plausible peer
/// addresses from the interface's own address and mask, add the historical
/// literals, then probe port 49152 with a short timeout.
struct TunnelEndpoint: Equatable {
    let address: String
    let port: UInt16
    let origin: String
}

enum TunnelProbe {

    static let developerPort: UInt16 = 49152
    static let connectTimeout: TimeInterval = 0.7

    /// Every address we are willing to try, best guess first.
    static func candidates() -> [TunnelEndpoint] {
        var out: [TunnelEndpoint] = []
        var seen = Set<String>()

        func add(_ address: String, _ origin: String) {
            guard !seen.contains(address) else { return }
            seen.insert(address)
            out.append(TunnelEndpoint(address: address, port: developerPort, origin: origin))
        }

        // 1. Tun interfaces, current subnets first.
        for interface in tunnelInterfaces() {
            for address in derivedPeers(for: interface) {
                add(address, "utun \(interface.name)")
            }
        }

        // 2. Historical literals. Loopback first: remotepairingd answers on
        //    127.0.0.1:49152 on current iOS, and it needs no tunnel at all.
        add("127.0.0.1", "loopback")
        add("10.7.0.1", "LocalDevVPN target")
        add("10.7.0.0", "LocalDevVPN device")
        add("10.7.0.2", "LocalDevVPN sibling")
        add("172.20.10.1", "personal hotspot")
        return out
    }

    /// Returns the first endpoint that accepts a TCP connection, or nil.
    static func discover(logger: ((String) -> Void)? = nil) -> TunnelEndpoint? {
        for candidate in candidates() {
            if canConnect(candidate, timeout: connectTimeout) {
                logger?("tunnel: \(candidate.address):\(candidate.port) reachable "
                        + "(\(candidate.origin))")
                return candidate
            }
        }
        logger?("tunnel: no endpoint answered on port \(developerPort)")
        return nil
    }

    // MARK: - Sockets

    static func canConnect(_ endpoint: TunnelEndpoint, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let port = String(endpoint.port)
        guard getaddrinfo(endpoint.address, port, &hints, &result) == 0, let info = result else {
            return false
        }
        defer { freeaddrinfo(info) }

        for node in sequence(first: info, next: { $0.pointee.ai_next }) {
            let fd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let status = connect(fd, node.pointee.ai_addr, node.pointee.ai_addrlen)
            if status == 0 { return true }
            guard errno == EINPROGRESS else { continue }

            var writeSet = fd_set()
            fdZero(&writeSet)
            fdSet(fd, &writeSet)
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            let ready = select(fd + 1, nil, &writeSet, nil, &tv)
            if ready > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 { return true }
            }
        }
        return false
    }

    // MARK: - Interfaces

    struct TunnelInterface {
        let name: String
        let address: String
        let netmask: String?
    }

    static func tunnelInterfaces() -> [TunnelInterface] {
        var out: [TunnelInterface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0 else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tap")
                    || name.hasPrefix("ppp") else { continue }
            guard let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let address = ipv4String(addr)
            let netmask = pointer.pointee.ifa_netmask.flatMap { ipv4String($0) }
            if let address {
                out.append(TunnelInterface(name: name, address: address, netmask: netmask))
            }
        }
        return out
    }

    /// Plausible peer addresses for a point-to-point interface: its own address,
    /// the /30 siblings, and the network/broadcast addresses for shorter masks.
    static func derivedPeers(for interface: TunnelInterface) -> [String] {
        guard let own = ipv4Value(interface.address) else { return [] }
        var out = [interface.address]

        if let maskString = interface.netmask, let mask = ipv4Value(maskString) {
            let network = own & mask
            let broadcast = own | ~mask
            let bits = mask.nonzeroBitCount
            if bits >= 30 {
                var value = network
                while value <= broadcast {
                    let candidate = ipv4String(value)
                    if let candidate, candidate != interface.address { out.append(candidate) }
                    value = value &+ 1
                }
            } else {
                if let net = ipv4String(network) { out.append(net) }
                for offset in 1...3 {
                    if let candidate = ipv4String(network &+ UInt32(offset)) { out.append(candidate) }
                }
                if let b = ipv4String(broadcast) { out.append(b) }
            }
        }
        return out
    }

    private static func ipv4String(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &sin, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func ipv4String(_ value: UInt32) -> String? {
        var v = value
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &v, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func ipv4Value(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        return addr.s_addr.byteSwapped
    }

    private static func fdZero(_ set: inout fd_set) {
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { raw in
                for i in 0..<32 { raw[i] = 0 }
            }
        }
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let index = Int(fd) / 32
        let bit = Int32(1) << (Int(fd) % 32)
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { raw in
                raw[index] |= bit
            }
        }
    }
}
