# beacon light client bridge
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  json_serialization/std/net,
  beacon_chain/light_client,
  beacon_chain/conf

export net, conf

proc defaultBridgeDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "BeaconLightClientBridge"
  elif defined(macosx):
    "Library" / "Application Support" / "BeaconLightClientBridge"
  else:
    ".cache" / "beacon-ligh-client-bridge"

  getHomeDir() / dataDir

const
  defaultBridgeDataDirDesc* = defaultBridgeDataDir()

type BridgeConf* = object
  # Config
  configFile* {.
    desc: "Loads the configuration from a TOML file"
    name: "config-file" .}: Option[InputFile]

  # Logging
  logLevel* {.
    desc: "Sets the log level"
    defaultValue: "INFO"
    name: "log-level" .}: string

  logStdout* {.
    hidden
    desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
    defaultValueDesc: "auto"
    defaultValue: StdoutLogKind.Auto
    name: "log-format" .}: StdoutLogKind

  # Storage
  dataDir* {.
    desc: "The directory where beacon light client bridge will store all data"
    defaultValue: defaultBridgeDataDir()
    defaultValueDesc: $defaultBridgeDataDirDesc
    abbr: "d"
    name: "data-dir" .}: OutDir

  # Consensus light sync
  # No default - Needs to be provided by the user
  trustedBlockRoot* {.
    desc: "Recent trusted finalized block root to initialize the consensus light client from"
    name: "trusted-block-root" .}: Eth2Digest

  # Libp2p
  bootstrapNodes* {.
    desc: "Specifies one or more bootstrap nodes to use when connecting to the network"
    abbr: "b"
    name: "bootstrap-node" .}: seq[string]

  bootstrapNodesFile* {.
    desc: "Specifies a line-delimited file of bootstrap Ethereum network addresses"
    defaultValue: ""
    name: "bootstrap-file" .}: InputFile

  listenAddress* {.
    desc: "Listening address for the Ethereum LibP2P and Discovery v5 traffic"
    defaultValue: defaultListenAddress
    defaultValueDesc: $defaultListenAddressDesc
    name: "listen-address" .}: ValidIpAddress

  tcpPort* {.
    desc: "Listening TCP port for Ethereum LibP2P traffic"
    defaultValue: defaultEth2TcpPort
    defaultValueDesc: $defaultEth2TcpPortDesc
    name: "tcp-port" .}: Port

  udpPort* {.
    desc: "Listening UDP port for node discovery"
    defaultValue: defaultEth2TcpPort
    defaultValueDesc: $defaultEth2TcpPortDesc
    name: "udp-port" .}: Port

  # TODO: Select a lower amount of peers.
  maxPeers* {.
    desc: "The target number of peers to connect to"
    defaultValue: 160 # 5 (fanout) * 64 (subnets) / 2 (subs) for a healthy mesh
    name: "max-peers" .}: int

  hardMaxPeers* {.
    desc: "The maximum number of peers to connect to. Defaults to maxPeers * 1.5"
    name: "hard-max-peers" .}: Option[int]

  nat* {.
    desc: "Specify method to use for determining public address. " &
          "Must be one of: any, none, upnp, pmp, extip:<IP>"
    defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
    defaultValueDesc: "any"
    name: "nat" .}: NatConfig

  enrAutoUpdate* {.
    desc: "Discovery can automatically update its ENR with the IP address " &
          "and UDP port as seen by other nodes it communicates with. " &
          "This option allows to enable/disable this functionality"
    defaultValue: false
    name: "enr-auto-update" .}: bool

  agentString* {.
    defaultValue: "nimbus",
    desc: "Node agent string which is used as identifier in the LibP2P network"
    name: "agent-string" .}: string

  discv5Enabled* {.
    desc: "Enable Discovery v5"
    defaultValue: true
    name: "discv5" .}: bool

  directPeers* {.
    desc: "The list of priviledged, secure and known peers to connect and" &
          "maintain the connection to, this requires a not random netkey-file." &
          "In the complete multiaddress format like:" &
          "/ip4/<address>/tcp/<port>/p2p/<peerId-public-key>." &
          "Peering agreements are established out of band and must be reciprocal"
    name: "direct-peer" .}: seq[string]


func asLightClientConf*(pc: BridgeConf): LightClientConf =
  return LightClientConf(
    configFile: pc.configFile,
    logLevel: pc.logLevel,
    logStdout: pc.logStdout,
    logFile: none(OutFile),
    dataDir: pc.dataDir,
    # Portal networks are defined only over mainnet therefore bridging makes
    # sense only for mainnet
    eth2Network: some("mainnet"),
    bootstrapNodes: pc.bootstrapNodes,
    bootstrapNodesFile: pc.bootstrapNodesFile,
    listenAddress: pc.listenAddress,
    tcpPort: pc.tcpPort,
    udpPort: pc.udpPort,
    maxPeers: pc.maxPeers,
    hardMaxPeers: pc.hardMaxPeers,
    nat: pc.nat,
    enrAutoUpdate: pc.enrAutoUpdate,
    agentString: pc.agentString,
    discv5Enabled: pc.discv5Enabled,
    directPeers: pc.directPeers,
    trustedBlockRoot: pc.trustedBlockRoot,
    web3Urls: @[],
    jwtSecret: none(string),
    stopAtEpoch: 0
  )
