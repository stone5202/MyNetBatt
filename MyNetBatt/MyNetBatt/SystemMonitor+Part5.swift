import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchNetworkDetails() {
        Task.detached {
            var interface = "--"
            var gateway = "--"
            var localIP = "--"

            let route = self.runCommand("/sbin/route", ["-n", "get", "default"])
            if let value = self.extract(pattern: #"(?m)^\s*interface:\s*([^\s]+)"#, from: route), !value.isEmpty {
                interface = value
            }
            if let value = self.extract(pattern: #"(?m)^\s*gateway:\s*([^\s]+)"#, from: route), !value.isEmpty {
                gateway = value
            }

            if interface == "--" || gateway == "--" {
                let routingTable = self.runCommand("/usr/sbin/netstat", ["-rn", "-f", "inet"])
                for line in routingTable.components(separatedBy: .newlines) {
                    let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    guard cols.count >= 4, cols.first == "default" else { continue }
                    if gateway == "--", cols.count > 1 { gateway = cols[1] }
                    if interface == "--", let candidate = cols.last, candidate.hasPrefix("en") || candidate.hasPrefix("bridge") || candidate.hasPrefix("utun") {
                        interface = candidate
                    }
                    break
                }
            }

            let allInterfaces = self.runCommand("/sbin/ifconfig", ["-l"])
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            var candidates: [String] = []
            if interface != "--" { candidates.append(interface) }
            candidates.append(contentsOf: allInterfaces.filter { !candidates.contains($0) && $0 != "lo0" })

            for candidate in candidates {
                let ip = self.runCommand("/usr/sbin/ipconfig", ["getifaddr", candidate])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty, ip != "127.0.0.1" {
                    localIP = ip
                    if interface == "--" { interface = candidate }
                    break
                }
            }

            if localIP == "--", interface != "--" {
                let ifconfig = self.runCommand("/sbin/ifconfig", [interface])
                if let ip = self.extract(pattern: #"(?m)^\s*inet\s+(\d+\.\d+\.\d+\.\d+)"#, from: ifconfig), ip != "127.0.0.1" {
                    localIP = ip
                }
            }

            if gateway == "--" {
                let routingTable = self.runCommand("/usr/sbin/netstat", ["-rn", "-f", "inet"])
                for line in routingTable.components(separatedBy: .newlines) {
                    let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    if cols.count > 1, cols.first == "default" {
                        gateway = cols[1]
                        break
                    }
                }
            }

            let dnsOutput = self.runCommand("/usr/sbin/scutil", ["--dns"])
            var dnsServers: [String] = []
            if let regex = try? NSRegularExpression(pattern: #"nameserver\[[0-9]+\]\s*:\s*([^\s]+)"#, options: []) {
                let ns = dnsOutput as NSString
                for match in regex.matches(in: dnsOutput, range: NSRange(location: 0, length: ns.length)) {
                    if match.numberOfRanges > 1 {
                        let value = ns.substring(with: match.range(at: 1))
                        if !dnsServers.contains(value) { dnsServers.append(value) }
                        if dnsServers.count >= 3 { break }
                    }
                }
            }
            let dns = dnsServers.isEmpty ? "--" : dnsServers.joined(separator: ", ")

            var publicIP = "無法取得"
            if localIP != "--" {
                let publicIPRaw = self.runCommand("/usr/bin/curl", ["-fsS", "--max-time", "2", "https://api.ipify.org"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !publicIPRaw.isEmpty { publicIP = publicIPRaw }
            }

            let fInterface = interface
            let fGateway = gateway
            let fLocalIP = localIP
            let fDNS = dns
            let fPublicIP = publicIP
            let isConnected = localIP != "--"
            await MainActor.run {
                self.networkInterfaceName = fInterface
                self.networkGateway = fGateway
                self.networkLocalIP = fLocalIP
                self.networkDNS = fDNS
                self.networkPublicIP = fPublicIP
                self.networkDetailStatus = isConnected ? "已連線" : "未連線"
            }
        }
    }

}
