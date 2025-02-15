# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, typetraits],
  eth/common,
  ../web3_eth_conv,
  ../beacon_engine,
  ../execution_types,
  ../../db/core_db,
  ./api_utils

{.push gcsafe, raises:[CatchableError].}

const
  maxBodyRequest = 32

proc getPayloadBodyByHeader(db: CoreDbRef,
        header: common.BlockHeader,
        output: var seq[Option[ExecutionPayloadBodyV1]]) =

  var body: common.BlockBody
  if not db.getBlockBody(header, body):
    output.add none(ExecutionPayloadBodyV1)
    return

  let txs = w3Txs body.transactions
  var wds: seq[WithdrawalV1]
  if body.withdrawals.isSome:
    for w in body.withdrawals.get:
      wds.add w3Withdrawal(w)

  output.add(
    some(ExecutionPayloadBodyV1(
      transactions: txs,
      # pre Shanghai block return null withdrawals
      # post Shanghai block return at least empty slice
      withdrawals: if header.withdrawalsRoot.isSome:
                     some(wds)
                   else:
                     none(seq[WithdrawalV1])
    ))
  )

proc getPayloadBodiesByHash*(ben: BeaconEngineRef,
                             hashes: seq[Web3Hash]):
                               seq[Option[ExecutionPayloadBodyV1]] =
  if hashes.len > maxBodyRequest:
    raise tooLargeRequest("request exceeds max allowed " & $maxBodyRequest)

  let db = ben.com.db
  var header: common.BlockHeader
  for h in hashes:
    if not db.getBlockHeader(ethHash h, header):
      result.add none(ExecutionPayloadBodyV1)
      continue
    db.getPayloadBodyByHeader(header, result)

proc getPayloadBodiesByRange*(ben: BeaconEngineRef,
                              start: uint64, count: uint64):
                                seq[Option[ExecutionPayloadBodyV1]] =
  if start == 0:
    raise invalidParams("start block should greater than zero")

  if count == 0:
    raise invalidParams("blocks count should greater than zero")

  if count > maxBodyRequest:
    raise tooLargeRequest("request exceeds max allowed " & $maxBodyRequest)

  let
    com = ben.com
    db  = com.db
    current = com.syncCurrent.truncate(uint64)

  var
    header: common.BlockHeader
    last = start+count-1

  if last > current:
    last = current

  for bn in start..last:
    if not db.getBlockHeader(bn.toBlockNumber, header):
      result.add none(ExecutionPayloadBodyV1)
      continue
    db.getPayloadBodyByHeader(header, result)
