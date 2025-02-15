# Nimbus
# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  unittest2,
  ../nimbus/common/common,
  ../nimbus/utils/utils

const
  MainNetIDs = [
    (number: 0'u64       , time: 0'u64, id: (crc: 0xfc64ec04'u32, next: 1150000'u64)), # Unsynced
    (number: 1149999'u64 , time: 0'u64, id: (crc: 0xfc64ec04'u32, next: 1150000'u64)), # Last Frontier block
    (number: 1150000'u64 , time: 0'u64, id: (crc: 0x97c2c34c'u32, next: 1920000'u64)), # First Homestead block
    (number: 1919999'u64 , time: 0'u64, id: (crc: 0x97c2c34c'u32, next: 1920000'u64)), # Last Homestead block
    (number: 1920000'u64 , time: 0'u64, id: (crc: 0x91d1f948'u32, next: 2463000'u64)), # First DAO block
    (number: 2462999'u64 , time: 0'u64, id: (crc: 0x91d1f948'u32, next: 2463000'u64)), # Last DAO block
    (number: 2463000'u64 , time: 0'u64, id: (crc: 0x7a64da13'u32, next: 2675000'u64)), # First Tangerine block
    (number: 2674999'u64 , time: 0'u64, id: (crc: 0x7a64da13'u32, next: 2675000'u64)), # Last Tangerine block
    (number: 2675000'u64 , time: 0'u64, id: (crc: 0x3edd5b10'u32, next: 4370000'u64)), # First Spurious block
    (number: 4369999'u64 , time: 0'u64, id: (crc: 0x3edd5b10'u32, next: 4370000'u64)), # Last Spurious block
    (number: 4370000'u64 , time: 0'u64, id: (crc: 0xa00bc324'u32, next: 7280000'u64)), # First Byzantium block
    (number: 7279999'u64 , time: 0'u64, id: (crc: 0xa00bc324'u32, next: 7280000'u64)), # Last Byzantium block
    (number: 7280000'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # First and last Constantinople, first Petersburg block
    (number: 7987396'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # Past Petersburg block
    (number: 9068999'u64 , time: 0'u64, id: (crc: 0x668db0af'u32, next: 9069000'u64)), # Last Petersburg block
    (number: 9069000'u64 , time: 0'u64, id: (crc: 0x879D6E30'u32, next: 9200000'u64)), # First Istanbul block
    (number: 9199999'u64 , time: 0'u64, id: (crc: 0x879D6E30'u32, next: 9200000'u64)), # Last Istanbul block
    (number: 9200000'u64 , time: 0'u64, id: (crc: 0xE029E991'u32, next: 12244000'u64)), # First MuirGlacier block
    (number: 12243999'u64, time: 0'u64, id: (crc: 0xE029E991'u32, next: 12244000'u64)), # Last MuirGlacier block
    (number: 12244000'u64, time: 0'u64, id: (crc: 0x0eb440f6'u32, next: 12965000'u64)), # First Berlin block
    (number: 12964999'u64, time: 0'u64, id: (crc: 0x0eb440f6'u32, next: 12965000'u64)), # Last Berlin block
    (number: 12965000'u64, time: 0'u64, id: (crc: 0xb715077d'u32, next: 13773000'u64)), # First London block
    (number: 13772999'u64, time: 0'u64, id: (crc: 0xb715077d'u32, next: 13773000'u64)), # Last London block
    (number: 13773000'u64, time: 0'u64, id: (crc: 0x20c327fc'u32, next: 15050000'u64)), # First Arrow Glacier block
    (number: 15049999'u64, time: 0'u64, id: (crc: 0x20c327fc'u32, next: 15050000'u64)), # Last Arrow Glacier block
    (number: 15050000'u64, time: 0'u64, id: (crc: 0xf0afd0e3'u32, next: 1681338455'u64)), # First Gray Glacier block
    (number: 20000000'u64, time: 1681338454'u64, id: (crc: 0xf0afd0e3'u32, next: 1681338455'u64)), # Last Gray Glacier block
    (number: 20000000'u64, time: 1681338455'u64, id: (crc: 0xdce96c2d'u32, next: 0'u64)),          # First Shanghai block
    (number: 30000000'u64, time: 2000000000'u64, id: (crc: 0xdce96c2d'u32, next: 0'u64)),          # Future Shanghai block
  ]

  GoerliNetIDs = [
    (number: 0'u64      , time: 0'u64, id: (crc: 0xa3f5ab08'u32, next: 1561651'u64)), # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople and first Petersburg block
    (number: 1561650'u64, time: 0'u64, id: (crc: 0xa3f5ab08'u32, next: 1561651'u64)), # Last Petersburg block
    (number: 1561651'u64, time: 0'u64, id: (crc: 0xc25efa5c'u32, next: 4460644'u64)), # First Istanbul block
    (number: 4460643'u64, time: 0'u64, id: (crc: 0xc25efa5c'u32, next: 4460644'u64)), # Future Istanbul block
    (number: 4460644'u64, time: 0'u64, id: (crc: 0x757a1c47'u32, next: 5062605'u64)), # First Berlin block
    (number: 5062604'u64, time: 0'u64, id: (crc: 0x757a1c47'u32, next: 5062605'u64)), # Last Berlin block
    (number: 5062605'u64, time: 0'u64, id: (crc: 0xb8c6299d'u32, next: 1678832736'u64)),         # First London block
    (number: 6000000'u64, time: 1678832735'u64, id: (crc: 0xB8C6299D'u32, next: 1678832736'u64)), # Last London block
    (number: 6000001'u64, time: 1678832736'u64, id: (crc: 0xf9843abf'u32, next: 0'u64)),          # First Shanghai block
    (number: 6500000'u64, time: 2678832736'u64, id: (crc: 0xf9843abf'u32, next: 0'u64)),          # Future Shanghai block
  ]

  SepoliaNetIDs = [
    (number: 0'u64,       time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1735371'u64)),             # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin and first London block
    (number: 1735370'u64, time: 0'u64, id: (crc: 0xfe3366e7'u32, next: 1735371'u64)),             # Last London block
    (number: 1735371'u64, time: 0'u64, id: (crc: 0xb96cbd13'u32, next: 1677557088'u64)),          # First MergeNetsplit block
    (number: 1735372'u64, time: 1677557087'u64, id: (crc: 0xb96cbd13'u32, next: 1677557088'u64)), # Last MergeNetsplit block
    (number: 1735372'u64, time: 1677557088'u64, id: (crc: 0xf7f9bc08'u32, next: 0'u64)),          # First Shanghai block
  ]

  HoleskyNetIDs = [
    (number: 0'u64,   time: 0'u64, id: (crc: 0xc61a6098'u32, next: 1696000704'u64)), # Unsynced, last Frontier, Homestead, Tangerine, Spurious, Byzantium, Constantinople, Petersburg, Istanbul, Berlin, London, Paris block
    (number: 123'u64, time: 0'u64, id: (crc: 0xc61a6098'u32, next: 1696000704'u64)), # First MergeNetsplit block
    (number: 123'u64, time: 1696000704'u64, id: (crc: 0xfd4f016b'u32, next: 0'u64)), # Last MergeNetsplit block
  ]

template runTest(network: untyped, name: string) =
  test name:
    var
      params = networkParams(network)
      com    = CommonRef.new(newCoreDbRef LegacyDbMemory, true, network, params)

    for i, x in `network IDs`:
      let id = com.forkId(x.number, x.time)
      check id.crc == x.id.crc
      check id.nextFork == x.id.next

func config(shanghai, cancun: uint64): ChainConfig =
  ChainConfig(
    chainID:                       ChainId(1337),
    homesteadBlock:                some(0.u256),
    dAOForkBlock:                  none(BlockNumber),
    dAOForkSupport:                true,
    eIP150Block:                   some(0.u256),
    eIP155Block:                   some(0.u256),
    eIP158Block:                   some(0.u256),
    byzantiumBlock:                some(0.u256),
    constantinopleBlock:           some(0.u256),
    petersburgBlock:               some(0.u256),
    istanbulBlock:                 some(0.u256),
    muirGlacierBlock:              some(0.u256),
    berlinBlock:                   some(0.u256),
    londonBlock:                   some(0.u256),
    terminalTotalDifficulty:       some(0.u256),
    terminalTotalDifficultyPassed: some(true),
    mergeForkBlock:                some(0.u256),
    shanghaiTime:                  some(shanghai.EthTime),
    cancunTime:                    some(cancun.EthTime),
  )

func calcID(conf: ChainConfig, crc: uint32, time: uint64): ForkID =
  let map  = conf.toForkTransitionTable
  let calc = map.initForkIdCalculator(crc, time)
  calc.newID(0, time)

template runGenesisTimeIdTests() =
  let
    time       = 1690475657'u64
    genesis    = common.BlockHeader(timestamp: time.EthTime)
    genesisCRC = crc32(0, genesis.blockHash.data)
    cases = [
      # Shanghai active before genesis, skip
      (c: config(time-1, time+1), want: (crc: genesisCRC, next: time + 1)),

      # Shanghai active at genesis, skip
      (c: config(time, time+1), want: (crc: genesisCRC, next: time + 1)),

      # Shanghai not active, skip
      (c: config(time+1, time+2), want: (crc: genesisCRC, next: time + 1)),
    ]

  for i, x in cases:
    let get = calcID(x.c, genesisCRC, time)
    check get.crc == x.want.crc
    check get.nextFork == x.want.next

proc forkIdMain*() =
  suite "Fork ID tests":
    runTest(MainNet, "MainNet")
    runTest(GoerliNet, "GoerliNet")
    runTest(SepoliaNet, "SepoliaNet")
    runTest(HoleskyNet, "HoleskyNet")
    test "Genesis Time Fork ID":
      runGenesisTimeIdTests()

when isMainModule:
  forkIdMain()
