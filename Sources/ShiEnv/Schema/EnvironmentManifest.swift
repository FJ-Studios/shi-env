import Foundation

// MARK: - EnvironmentManifest
//
// Codable Swift representation of the .shikki/env/<name>.yml inventory file.
// Schema version: 1 (BR-SEIS-02).
//
// Spec: features/shi-env-inventory-schema-2026-05-31.md §3.2

// MARK: Addressing

public struct EnvAddressing: Codable, Sendable, Equatable {
    public var workspace: String
    public var project: String
    public var environment: String

    public init(workspace: String, project: String, environment: String) {
        self.workspace = workspace
        self.project = project
        self.environment = environment
    }

    /// Dot-separated address string (e.g. "obyw-one.obyw-one.prod").
    public var dotAddress: String { "\(workspace).\(project).\(environment)" }
}

// MARK: Provider

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case local
    case ovhVps = "ovh-vps"
    case hetznerVps = "hetzner-vps"
    case awsEc2 = "aws-ec2"
    case scaleway
    case tailscaleOverlay = "tailscale-overlay"
}

public struct ProviderSSH: Codable, Sendable, Equatable {
    public var user: String
    /// Vault URI for the SSH private key — NEVER a literal path (BR-SEIS-04).
    public var key_ref: String

    public init(user: String, key_ref: String) {
        self.user = user
        self.key_ref = key_ref
    }
}

public struct KotobaClockSyncTier: RawRepresentable, Codable, Sendable, Equatable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    // Canonical tiers from ShiTimeClient AccuracyClass (shi-time-sync W1)
    public static let unsynced      = KotobaClockSyncTier(rawValue: "unsynced")
    public static let appLayer      = KotobaClockSyncTier(rawValue: "app_layer")
    public static let ntpLstratum   = KotobaClockSyncTier(rawValue: "ntp_lstratum")
    public static let gptp          = KotobaClockSyncTier(rawValue: "gptp")
}

public struct KotobaBlock: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var nats_subject: String
    public var streams: [String]
    public var clock_sync_tier: KotobaClockSyncTier
    public var library: String?

    public init(
        enabled: Bool,
        nats_subject: String,
        streams: [String],
        clock_sync_tier: KotobaClockSyncTier,
        library: String? = nil
    ) {
        self.enabled = enabled
        self.nats_subject = nats_subject
        self.streams = streams
        self.clock_sync_tier = clock_sync_tier
        self.library = library
    }
}

public struct ProviderBlock: Codable, Sendable, Equatable {
    public var kind: ProviderKind
    public var host: String
    public var region: String?
    public var capabilities: [String]?
    public var resolver_plugin: String?
    public var ssh: ProviderSSH?
    /// Optional Kotoba fleet AV/input pipeline block (BR-SEIS-13).
    public var kotoba: KotobaBlock?

    public init(
        kind: ProviderKind,
        host: String,
        region: String? = nil,
        capabilities: [String]? = nil,
        resolver_plugin: String? = nil,
        ssh: ProviderSSH? = nil,
        kotoba: KotobaBlock? = nil
    ) {
        self.kind = kind
        self.host = host
        self.region = region
        self.capabilities = capabilities
        self.resolver_plugin = resolver_plugin
        self.ssh = ssh
        self.kotoba = kotoba
    }
}

// MARK: Services

public struct BridgeEntry: Codable, Sendable, Equatable {
    public var local_port: Int
    public var remote_port: Int
    public var auth: String
    public var open_path: String?
    public var description: String?

    public init(
        local_port: Int,
        remote_port: Int,
        auth: String,
        open_path: String? = nil,
        description: String? = nil
    ) {
        self.local_port = local_port
        self.remote_port = remote_port
        self.auth = auth
        self.open_path = open_path
        self.description = description
    }
}

public struct ObservabilityEntry: Codable, Sendable, Equatable {
    public var kurma_slug: String
    public var probes: [String]?

    public init(kurma_slug: String, probes: [String]? = nil) {
        self.kurma_slug = kurma_slug
        self.probes = probes
    }
}

public struct SystemdBlock: Codable, Sendable, Equatable {
    public var unit: String
    public var user: String?

    public init(unit: String, user: String? = nil) {
        self.unit = unit
        self.user = user
    }
}

public struct ServiceDep: Codable, Sendable, Equatable {
    /// Name of another service in the SAME environment.
    public var service: String?
    /// External system name (e.g. "restic-backup").
    public var external: String?

    public init(service: String? = nil, external: String? = nil) {
        self.service = service
        self.external = external
    }
}

public struct BackupsBlock: Codable, Sendable, Equatable {
    public var restic_target: String?
    public var schedule: String?

    public init(restic_target: String? = nil, schedule: String? = nil) {
        self.restic_target = restic_target
        self.schedule = schedule
    }
}

public struct ServiceEntry: Codable, Sendable, Equatable {
    public var image: String?
    public var ports: [String: Int]?
    public var bridges: [String: BridgeEntry]?
    public var public_paths: [String]?
    public var blocked_paths: [String]?
    public var secrets_refs: [String: String]?
    public var observability: ObservabilityEntry?
    public var systemd: SystemdBlock?
    public var deps: [ServiceDep]?
    public var backups: BackupsBlock?
    public var config_generator: String?
    public var upstream_services: [String]?

    public init(
        image: String? = nil,
        ports: [String: Int]? = nil,
        bridges: [String: BridgeEntry]? = nil,
        public_paths: [String]? = nil,
        blocked_paths: [String]? = nil,
        secrets_refs: [String: String]? = nil,
        observability: ObservabilityEntry? = nil,
        systemd: SystemdBlock? = nil,
        deps: [ServiceDep]? = nil,
        backups: BackupsBlock? = nil,
        config_generator: String? = nil,
        upstream_services: [String]? = nil
    ) {
        self.image = image
        self.ports = ports
        self.bridges = bridges
        self.public_paths = public_paths
        self.blocked_paths = blocked_paths
        self.secrets_refs = secrets_refs
        self.observability = observability
        self.systemd = systemd
        self.deps = deps
        self.backups = backups
        self.config_generator = config_generator
        self.upstream_services = upstream_services
    }
}

// MARK: Clients / Agencies

public enum ClientType: String, Codable, Sendable, CaseIterable {
    case agencyClient = "agency-client"
    case assimilatedClient = "assimilated-client"
    case agencyProduct = "agency-product"
    case agencyProperty = "agency-property"
    case agencyInternal = "agency-internal"
    case crossAgency = "cross-agency"
}

public enum ClientPhase: String, Codable, Sendable, CaseIterable {
    case pending
    case promoted
    case graduated
    case prod
}

public struct ClientEntry: Codable, Sendable, Equatable {
    public var slug: String
    public var source_agency: String?
    public var operating_agency: String
    public var type: ClientType
    public var phase: ClientPhase
    public var scopes: [String]?

    public init(
        slug: String,
        source_agency: String? = nil,
        operating_agency: String,
        type: ClientType,
        phase: ClientPhase,
        scopes: [String]? = nil
    ) {
        self.slug = slug
        self.source_agency = source_agency
        self.operating_agency = operating_agency
        self.type = type
        self.phase = phase
        self.scopes = scopes
    }
}

public enum AgencyRole: String, Codable, Sendable {
    case sourceOnly = "source-only"
    case sourceAndOps = "source-and-ops"
    case opsOnly = "ops-only"
}

public enum AgencyType: String, Codable, Sendable {
    case developerStudio = "developer-studio"
    case digitalAgency = "digital-agency"
    case standaloneClient = "standalone-client"
}

public struct AgencyEntry: Codable, Sendable, Equatable {
    public var slug: String
    public var name: String
    public var type: AgencyType
    public var gh_org: String
    public var role: AgencyRole
    /// Slug ref to another agency that operates infra for this one.
    public var assimilated_to: String?

    public init(
        slug: String,
        name: String,
        type: AgencyType,
        gh_org: String,
        role: AgencyRole,
        assimilated_to: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.type = type
        self.gh_org = gh_org
        self.role = role
        self.assimilated_to = assimilated_to
    }
}

// MARK: Observability + Secrets backbone

public struct ObservabilityBackbone: Codable, Sendable, Equatable {
    public var kurma_endpoint: String
    public var kurma_admin_token_ref: String?

    public init(kurma_endpoint: String, kurma_admin_token_ref: String? = nil) {
        self.kurma_endpoint = kurma_endpoint
        self.kurma_admin_token_ref = kurma_admin_token_ref
    }
}

public struct SecretsBroker: Codable, Sendable, Equatable {
    public var endpoint: String
    public var client_id_ref: String?
    public var client_secret_ref: String?

    public init(endpoint: String, client_id_ref: String? = nil, client_secret_ref: String? = nil) {
        self.endpoint = endpoint
        self.client_id_ref = client_id_ref
        self.client_secret_ref = client_secret_ref
    }
}

// MARK: EnvironmentManifest (root)

/// The root inventory document for one environment.
///
/// Corresponds to `.shikki/env/<name>.yml`. After loading, pass through
/// ``InheritanceResolver`` to merge parent fields before use.
public struct EnvironmentManifest: Codable, Sendable, Equatable {
    /// Schema version. Must be `1` for this parser (BR-SEIS-02).
    public var version: Int
    public var addressing: EnvAddressing
    /// Optional parent environment name within the SAME workspace.project
    /// (e.g. `"prod"` for a local env). Resolved by `InheritanceResolver`.
    public var inherits_from: String?
    public var provider: ProviderBlock
    public var services: [String: ServiceEntry]?
    public var agencies: [AgencyEntry]?
    public var clients: [ClientEntry]?
    public var observability_backbone: ObservabilityBackbone?
    public var secrets_broker: SecretsBroker?

    public init(
        version: Int = 1,
        addressing: EnvAddressing,
        inherits_from: String? = nil,
        provider: ProviderBlock,
        services: [String: ServiceEntry]? = nil,
        agencies: [AgencyEntry]? = nil,
        clients: [ClientEntry]? = nil,
        observability_backbone: ObservabilityBackbone? = nil,
        secrets_broker: SecretsBroker? = nil
    ) {
        self.version = version
        self.addressing = addressing
        self.inherits_from = inherits_from
        self.provider = provider
        self.services = services
        self.agencies = agencies
        self.clients = clients
        self.observability_backbone = observability_backbone
        self.secrets_broker = secrets_broker
    }
}

// MARK: YAML parsing helper

extension EnvironmentManifest {
    /// Parse from YAML data. Uses a minimal YAML→JSON bridge (no external deps).
    ///
    /// For the test suite, fixtures ship as JSON (equivalent schema). Production
    /// callers use the Yams / swift-yaml dependency when added in a future wave.
    public static func decode(fromJSON data: Data) throws -> EnvironmentManifest {
        let decoder = JSONDecoder()
        return try decoder.decode(EnvironmentManifest.self, from: data)
    }

    /// Encode to JSON data.
    public func encodeToJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
