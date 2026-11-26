import Foundation

/// What one heart rate broadcaster advertised during a scan.
public struct Advertisement: Sendable, Equatable {
    public var localName: String?
    public var peripheralName: String?
    public var manufacturerData: Data?
    /// Advertised service UUID strings as CoreBluetooth prints them, such as "180D".
    public var serviceUUIDs: [String]

    public init(
        localName: String? = nil, peripheralName: String? = nil, manufacturerData: Data? = nil,
        serviceUUIDs: [String] = []
    ) {
        self.localName = localName
        self.peripheralName = peripheralName
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
    }

    public var names: [String] {
        [localName, peripheralName].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The advertised local name, else the peripheral name, else "no name".
    public var displayName: String { names.first ?? "no name" }

    /// The Bluetooth SIG company identifier: the first two bytes of the
    /// manufacturer data, little-endian.
    public var companyID: UInt16? {
        guard let manufacturerData, manufacturerData.count >= 2 else { return nil }
        let bytes = Array(manufacturerData.prefix(2))
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    public var companyHex: String? { companyID.map(Self.hex16) }

    /// Up to eight bytes of manufacturer payload after the company identifier,
    /// in hex, with "…" when there is more.
    public var manufacturerPrefix: String? {
        guard let manufacturerData, manufacturerData.count >= 2 else { return nil }
        let payload = Array(manufacturerData.dropFirst(2))
        let shown = payload.prefix(8).map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        return payload.count > 8 ? shown + "…" : shown
    }

    public var advertisesHeartRate: Bool {
        serviceUUIDs.contains { Self.shortUUID($0) == StrapMatch.heartRateService }
    }

    /// One line for the menu and setup guide, for example
    /// "WHOOP 4C1234 · company 0x1234, data 0A0B · services 180D".
    public var summary: String {
        let manufacturer: String
        if let companyHex {
            let data = manufacturerPrefix ?? ""
            manufacturer = data.isEmpty ? "company \(companyHex)" : "company \(companyHex), data \(data)"
        } else {
            manufacturer = "no manufacturer data"
        }
        let services = serviceUUIDs.isEmpty ? "no services listed" : "services " + serviceUUIDs.joined(separator: ", ")
        return "\(displayName) · \(manufacturer) · \(services)"
    }

    /// Merges a later discovery of the same peripheral, such as a scan response
    /// that adds a name, without dropping what was already heard.
    func merged(with newer: Advertisement) -> Advertisement {
        var result = self
        if let name = newer.localName, !name.isEmpty { result.localName = name }
        if let name = newer.peripheralName, !name.isEmpty { result.peripheralName = name }
        if let data = newer.manufacturerData { result.manufacturerData = data }
        for uuid in newer.serviceUUIDs where !result.serviceUUIDs.contains(uuid) { result.serviceUUIDs.append(uuid) }
        return result
    }

    static func hex16(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// "0000180D-0000-1000-8000-00805F9B34FB" and "180d" both become "180D".
    static func shortUUID(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        let base = "-0000-1000-8000-00805F9B34FB"
        if upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix(base) {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }
}

public enum StrapMatch {
    public static let heartRateService = "180D"

    /// Bluetooth SIG company identifiers assigned to WHOOP, Inc.
    ///
    /// Intentionally empty. WHOOP, Inc. does not appear in the Bluetooth SIG
    /// Assigned Numbers company identifier list (assigned_numbers/
    /// company_identifiers/company_identifiers.yaml in bitbucket.org/
    /// bluetooth-SIG/public, checked 2026-11-20: 4,081 entries up to 0x1152).
    /// Add the identifier here once one is assigned, or once scan diagnostics
    /// show which identifier a real strap advertises.
    public static let whoopCompanyIDs: Set<UInt16> = []

    /// A WHOOP by name ("whoop" anywhere, any case) or by company identifier.
    public static func isWhoop(
        names: [String], companyID: UInt16?, whoopCompanyIDs: Set<UInt16> = whoopCompanyIDs
    ) -> Bool {
        if names.contains(where: { $0.lowercased().contains("whoop") }) { return true }
        if let companyID, whoopCompanyIDs.contains(companyID) { return true }
        return false
    }

    public static func isWhoop(_ advertisement: Advertisement, whoopCompanyIDs: Set<UInt16> = whoopCompanyIDs) -> Bool {
        isWhoop(names: advertisement.names, companyID: advertisement.companyID, whoopCompanyIDs: whoopCompanyIDs)
    }

    /// A remembered strap is matched by its Bluetooth identifier only. Before
    /// that, any name containing "whoop" in any case qualifies.
    public static func accepts(id: UUID, names: [String], preferredID: UUID?) -> Bool {
        if let preferredID { return id == preferredID }
        return isWhoop(names: names, companyID: nil)
    }

    /// Matches a scan discovery. Without a remembered strap, the broadcaster
    /// must offer the Heart Rate Service (0x180D) and look like a WHOOP by name
    /// or company identifier. `viaHeartRateFilter` is true when the scan was
    /// filtered on 0x180D, which proves the service even if the advertisement
    /// packet did not list it.
    public static func accepts(
        id: UUID, advertisement: Advertisement, preferredID: UUID?, viaHeartRateFilter: Bool = false,
        whoopCompanyIDs: Set<UInt16> = whoopCompanyIDs
    ) -> Bool {
        if let preferredID { return id == preferredID }
        guard viaHeartRateFilter || advertisement.advertisesHeartRate else { return false }
        return isWhoop(advertisement, whoopCompanyIDs: whoopCompanyIDs)
    }
}
