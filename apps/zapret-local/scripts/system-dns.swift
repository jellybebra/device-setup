// A temporary supplemental resolver disappears when this process exits, including on SIGKILL.
// The DHCP service and its scoped/local resolvers remain owned by macOS.
import Foundation
import SystemConfiguration
import Darwin

guard CommandLine.arguments.count == 2, let port = UInt16(CommandLine.arguments[1]), port == 53 || port >= 1024 else { exit(2) }
guard let store = SCDynamicStoreCreate(nil, "Zapret Local DNS" as CFString, nil, nil) else { exit(1) }
let key = SCDynamicStoreKeyCreateNetworkServiceEntity(nil, kSCDynamicStoreDomainState,
                                                      "com.jellybebra.zapret-cudy" as CFString, kSCEntNetDNS)
let settings: [String: Any] = [
    kSCPropNetDNSServerAddresses as String: ["127.0.0.1"],
    kSCPropNetDNSServerPort as String: Int(port),
    kSCPropNetDNSSupplementalMatchDomains as String: [""],
    kSCPropNetDNSSupplementalMatchOrders as String: [1000],
]
guard SCDynamicStoreAddTemporaryValue(store, key, settings as CFDictionary) else { exit(2) }
withExtendedLifetime(store) { while true { pause() } }
