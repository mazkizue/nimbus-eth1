# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Rewrite of `core_apps.nim` using the new `CoreDb` API. The original
## `core_apps.nim` was renamed `core_apps_legacy.nim`.

{.push raises: [].}

import
  std/[algorithm, options, sequtils],
  chronicles,
  eth/[common, rlp],
  results,
  stew/byteutils,
  "../.."/[errors, constants],
  ".."/[aristo, storage_types],
  "."/base

logScope:
  topics = "core_db-apps"

type
  TransactionKey = tuple
    blockNumber: BlockNumber
    index: int

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var BlockHeader;
      ): bool
      {.gcsafe, raises: [RlpError].}

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash256;
      ): BlockHeader
      {.gcsafe, raises: [BlockNotFound].}

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].}

proc addBlockNumberToHashLookup*(
    db: CoreDbRef;
    header: BlockHeader;
      ) {.gcsafe.}

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool
      {.gcsafe.}

# Copied from `utils/utils` which cannot be imported here in order to
# avoid circular imports.
func hash(b: BlockHeader): Hash256

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Core apps " & info

template discardRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    warn logTxt info, error=($e.name), msg=e.msg

# ------------------------------------------------------------------------------
# Private iterators
# ------------------------------------------------------------------------------

iterator findNewAncestors(
    db: CoreDbRef;
    header: BlockHeader;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Returns the chain leading up from the given header until the first
  ## ancestor it has in common with our canonical chain.
  var h = header
  var orig: BlockHeader
  while true:
    if db.getBlockHeader(h.blockNumber, orig) and orig.hash == h.hash:
      break

    yield h

    if h.parentHash == GENESIS_PARENT_HASH:
      break
    else:
      h = db.getBlockHeader(h.parentHash)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator getBlockTransactionData*(
    db: CoreDbRef;
    transactionRoot: Hash256;
      ): Blob =
  block body:
    let root = db.getRoot(transactionRoot).valueOr:
      warn logTxt "getBlockTransactionData()",
        transactionRoot, action="getRoot()", `error`=($$error)
      break body
    let transactionDb = db.newMpt root
    var transactionIdx = 0
    while true:
      let transactionKey = rlp.encode(transactionIdx)
      let data = transactionDb.fetch(transactionKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getBlockTransactionData()", transactionRoot,
            transactionKey, action="fetch()", error=($$error)
        break body
      yield data
      inc transactionIdx


iterator getBlockTransactions*(
    db: CoreDbRef;
    header: BlockHeader;
      ): Transaction
      {.gcsafe, raises: [RlpError].} =
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    yield rlp.decode(encodedTx, Transaction)


iterator getBlockTransactionHashes*(
    db: CoreDbRef;
    blockHeader: BlockHeader;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  ## Returns an iterable of the transaction hashes from th block specified
  ## by the given block header.
  for encodedTx in db.getBlockTransactionData(blockHeader.txRoot):
    let tx = rlp.decode(encodedTx, Transaction)
    yield rlpHash(tx) # beware EIP-4844


iterator getWithdrawalsData*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): Blob =
  block body:
    let root = db.getRoot(withdrawalsRoot).valueOr:
      warn logTxt "getWithdrawalsData()",
        withdrawalsRoot, action="getRoot()", error=($$error)
      break body
    let wddb = db.newMpt root
    var idx = 0
    while true:
      let wdKey = rlp.encode(idx)
      let data = wddb.fetch(wdKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getWithdrawalsData()",
            withdrawalsRoot, wdKey, action="fetch()", error=($$error)
        break body
      yield data
      inc idx


iterator getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): Receipt
      {.gcsafe, raises: [RlpError].} =
  block body:
    let root = db.getRoot(receiptRoot).valueOr:
      warn logTxt "getWithdrawalsData()",
        receiptRoot, action="getRoot()", error=($$error)
      break body
    var receiptDb = db.newMpt root
    var receiptIdx = 0
    while true:
      let receiptKey = rlp.encode(receiptIdx)
      let receiptData = receiptDb.fetch(receiptKey).valueOr:
        if error.error != MptNotFound:
          warn logTxt "getWithdrawalsData()",
            receiptRoot, receiptKey, action="hasKey()", error=($$error)
        break body
      yield rlp.decode(receiptData, Receipt)
      inc receiptIdx

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func hash(b: BlockHeader): Hash256 =
  rlpHash(b)

proc removeTransactionFromCanonicalChain(
    db: CoreDbRef;
    transactionHash: Hash256;
      ) =
  ## Removes the transaction specified by the given hash from the canonical
  ## chain.
  db.newKvt.del(transactionHashToBlockKey(transactionHash).toOpenArray).isOkOr:
    warn logTxt "removeTransactionFromCanonicalChain()",
      transactionHash, action="del()", error=($$error)

proc setAsCanonicalChainHead(
    db: CoreDbRef;
    headerHash: Hash256;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Sets the header as the canonical chain HEAD.
  let header = db.getBlockHeader(headerHash)

  var newCanonicalHeaders = sequtils.toSeq(db.findNewAncestors(header))
  reverse(newCanonicalHeaders)
  for h in newCanonicalHeaders:
    var oldHash: Hash256
    if not db.getBlockHash(h.blockNumber, oldHash):
      break

    let oldHeader = db.getBlockHeader(oldHash)
    for txHash in db.getBlockTransactionHashes(oldHeader):
      db.removeTransactionFromCanonicalChain(txHash)
      # TODO re-add txn to internal pending pool (only if local sender)

  for h in newCanonicalHeaders:
    db.addBlockNumberToHashLookup(h)

  let canonicalHeadHash = canonicalHeadHashKey()
  db.newKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "setAsCanonicalChainHead()",
      canonicalHeadHash, action="put()", error=($$error)

  return newCanonicalHeaders

proc markCanonicalChain(
    db: CoreDbRef;
    header: BlockHeader;
    headerHash: Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  ## mark this chain as canonical by adding block number to hash lookup
  ## down to forking point
  var
    currHash = headerHash
    currHeader = header

  # mark current header as canonical
  let
    kvt = db.newKvt()
    key = blockNumberToHashKey(currHeader.blockNumber)
  kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
    warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
    return false

  # it is a genesis block, done
  if currHeader.parentHash == Hash256():
    return true

  # mark ancestor blocks as canonical too
  currHash = currHeader.parentHash
  if not db.getBlockHeader(currHeader.parentHash, currHeader):
    return false

  while currHash != Hash256():
    let key = blockNumberToHashKey(currHeader.blockNumber)
    let data = kvt.getOrEmpty(key.toOpenArray).valueOr:
      warn logTxt "markCanonicalChain()", key, action="get()", error=($$error)
      return false
    if data.len == 0:
      # not marked, mark it
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
    elif rlp.decode(data, Hash256) != currHash:
      # replace prev chain
      kvt.put(key.toOpenArray, rlp.encode(currHash)).isOkOr:
        warn logTxt "markCanonicalChain()", key, action="put()", error=($$error)
    else:
      # forking point, done
      break

    if currHeader.parentHash == Hash256():
      break

    currHash = currHeader.parentHash
    if not db.getBlockHeader(currHeader.parentHash, currHeader):
      return false

  return true


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc exists*(db: CoreDbRef, hash: Hash256): bool =
  db.newKvt(Shared).hasKey(hash.data).valueOr:
    warn logTxt "exisis()", hash, action="hasKey()", error=($$error)
    return false

proc getBlockHeader*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockHeader;
      ): bool =
  const info = "getBlockHeader()"
  let data = db.newKvt(Shared)
               .get(genericHashKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt info, blockHash, action="get()", error=($$error)
    return false

  discardRlpException info:
    output = rlp.decode(data, BlockHeader)
    return true

proc getBlockHeader*(
    db: CoreDbRef,
    blockHash: Hash256;
      ): BlockHeader =
  ## Returns the requested block header as specified by block hash.
  ##
  ## Raises BlockNotFound if it is not present in the db.
  if not db.getBlockHeader(blockHash, result):
    raise newException(
      BlockNotFound, "No block with hash " & blockHash.data.toHex)

proc getHash(
    db: CoreDbRef;
    key: DbKey;
    output: var Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  let data = db.newKvt(Shared).get(key.toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt "getHash()", key, action="get()", error=($$error)
    return false
  output = rlp.decode(data, Hash256)
  true

proc getCanonicalHead*(
    db: CoreDbRef;
    output: var BlockHeader;
      ): bool =
  discardRlpException "getCanonicalHead()":
    var headHash: Hash256
    if db.getHash(canonicalHeadHashKey(), headHash) and
       db.getBlockHeader(headHash, output):
      return true

proc getCanonicalHead*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [EVMError].} =
  if not db.getCanonicalHead result:
    raise newException(
      CanonicalHeadNotFound, "No canonical head set for this chain")

proc getCanonicalHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  discard db.getHash(canonicalHeadHashKey(), result)

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var Hash256;
      ): bool =
  ## Return the block hash for the given block number.
  db.getHash(blockNumberToHashKey(n), output)

proc getBlockHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Hash256
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Return the block hash for the given block number.
  if not db.getHash(blockNumberToHashKey(n), result):
    raise newException(BlockNotFound, "No block hash for number " & $n)

proc getHeadBlockHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  if not db.getHash(canonicalHeadHashKey(), result):
    result = Hash256()

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
    output: var BlockHeader;
      ): bool =
  ## Returns the block header with the given number in the canonical chain.
  var blockHash: Hash256
  if db.getBlockHash(n, blockHash):
    result = db.getBlockHeader(blockHash, output)

proc getBlockHeaderWithHash*(
    db: CoreDbRef;
    n: BlockNumber;
      ): Option[(BlockHeader, Hash256)]
      {.gcsafe, raises: [RlpError].} =
  ## Returns the block header and its hash, with the given number in the
  ## canonical chain. Hash is returned to avoid recomputing it
  var hash: Hash256
  if db.getBlockHash(n, hash):
    # Note: this will throw if header is not present.
    var header: BlockHeader
    if db.getBlockHeader(hash, header):
      return some((header, hash))
    else:
      # this should not happen, but if it happen lets fail laudly as this means
      # something is super wrong
      raiseAssert("Corrupted database. Mapping number->hash present, without header in database")
  else:
    return none[(BlockHeader, Hash256)]()

proc getBlockHeader*(
    db: CoreDbRef;
    n: BlockNumber;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  ## Returns the block header with the given number in the canonical chain.
  ## Raises BlockNotFound error if the block is not in the DB.
  db.getBlockHeader(db.getBlockHash(n))

proc getScore*(
    db: CoreDbRef;
    blockHash: Hash256;
      ): UInt256
      {.gcsafe, raises: [RlpError].} =
  let data = db.newKvt(Shared)
               .get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt "getScore()", blockHash, action="get()", error=($$error)
    return
  rlp.decode(data, UInt256)

proc setScore*(db: CoreDbRef; blockHash: Hash256, score: UInt256) =
  ## for testing purpose
  let scoreKey = blockHashToScoreKey blockHash
  db.newKvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn logTxt "setScore()", scoreKey, action="put()", error=($$error)
    return

proc getTd*(db: CoreDbRef; blockHash: Hash256, td: var UInt256): bool =
  const info = "getId()"
  let bytes = db.newKvt(Shared)
                .get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
    if error.error != KvtNotFound:
      warn logTxt info, blockHash, action="get()", error=($$error)
    return false
  discardRlpException info:
    td = rlp.decode(bytes, UInt256)
    return true

proc headTotalDifficulty*(
    db: CoreDbRef;
      ): UInt256
      {.gcsafe, raises: [RlpError].} =
  # this is actually a combination of `getHash` and `getScore`
  const
    info = "headTotalDifficulty()"
    key = canonicalHeadHashKey()
  let
    kvt = db.newKvt(Shared)
    data = kvt.get(key.toOpenArray).valueOr:
      if error.error != KvtNotFound:
        warn logTxt info, key, action="get()", error=($$error)
      return 0.u256
    blockHash = rlp.decode(data, Hash256)
    numData = kvt.get(blockHashToScoreKey(blockHash).toOpenArray).valueOr:
      warn logTxt info, blockHash, action="get()", error=($$error)
      return 0.u256

  rlp.decode(numData, UInt256)

proc getAncestorsHashes*(
    db: CoreDbRef;
    limit: UInt256;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [BlockNotFound].} =
  var ancestorCount = min(header.blockNumber, limit).truncate(int)
  var h = header

  result = newSeq[Hash256](ancestorCount)
  while ancestorCount > 0:
    h = db.getBlockHeader(h.parentHash)
    result[ancestorCount - 1] = h.hash
    dec ancestorCount

proc addBlockNumberToHashLookup*(db: CoreDbRef; header: BlockHeader) =
  let blockNumberKey = blockNumberToHashKey(header.blockNumber)
  db.newKvt.put(blockNumberKey.toOpenArray, rlp.encode(header.hash)).isOkOr:
    warn logTxt "addBlockNumberToHashLookup()",
      blockNumberKey, action="put()", error=($$error)

proc persistTransactions*(
    db: CoreDbRef;
    blockNumber: BlockNumber;
    transactions: openArray[Transaction];
      ): Hash256 =
  const
    info = "persistTransactions()"
  let
    mpt = db.newMpt()
    kvt = db.newKvt()
  for idx, tx in transactions:
    let
      encodedTx = rlp.encode(tx.removeNetworkPayload)
      txHash = rlpHash(tx) # beware EIP-4844
      blockKey = transactionHashToBlockKey(txHash)
      txKey: TransactionKey = (blockNumber, idx)
    mpt.merge(rlp.encode(idx), encodedTx).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)
      return EMPTY_ROOT_HASH
    kvt.put(blockKey.toOpenArray, rlp.encode(txKey)).isOkOr:
      warn logTxt info, blockKey, action="put()", error=($$error)
      return EMPTY_ROOT_HASH
  mpt.rootVid.hash(update=true).valueOr:
    warn logTxt info, action="hash()"
    return EMPTY_ROOT_HASH

proc getTransaction*(
    db: CoreDbRef;
    txRoot: Hash256;
    txIndex: int;
    res: var Transaction;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  const
    info = "getTransaction()"
  let
    mpt = block:
      let root = db.getRoot(txRoot).valueOr:
        warn logTxt info, txRoot, action="getRoot()", `error`=($$error)
        return false
      db.newMpt root
    txData = mpt.fetch(rlp.encode(txIndex)).valueOr:
      if error.error != MptNotFound:
        warn logTxt info, txIndex, action="fetch()", `error`=($$error)
      return false
  res = rlp.decode(txData, Transaction)
  true

proc getTransactionCount*(
    db: CoreDbRef;
    txRoot: Hash256;
      ): int =
  const
    info = "getTransactionCount()"
  let mpt = block:
    let root = db.getRoot(txRoot).valueOr:
      warn logTxt info, txRoot, action="getRoot()", `error`=($$error)
      return 0
    db.newMpt root
  var txCount = 0
  while true:
    let hasPath = mpt.hasPath(rlp.encode(txCount)).valueOr:
      warn logTxt info, txCount, action="hasPath()", `error`=($$error)
      return 0
    if hasPath:
      inc txCount
    else:
      return txCount

  doAssert(false, "unreachable")

proc getUnclesCount*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): int
      {.gcsafe, raises: [RlpError].} =
  const info = "getUnclesCount()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.newKvt(Shared).get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt info, ommersHash, action="get()", `error`=($$error)
        return 0
    return rlpFromBytes(encodedUncles).listLen

proc getUncles*(
    db: CoreDbRef;
    ommersHash: Hash256;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError].} =
  const info = "getUncles()"
  if ommersHash != EMPTY_UNCLE_HASH:
    let  encodedUncles = block:
      let key = genericHashKey(ommersHash)
      db.newKvt(Shared).get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt info, ommersHash, action="get()", `error`=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[BlockHeader])

proc persistWithdrawals*(
    db: CoreDbRef;
    withdrawals: openArray[Withdrawal];
      ): Hash256 =
  const info = "persistWithdrawals()"
  let mpt = db.newMpt()
  for idx, wd in withdrawals:
    mpt.merge(rlp.encode(idx), rlp.encode(wd)).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)
      return EMPTY_ROOT_HASH
  mpt.rootVid.hash(update=true).valueOr:
    warn logTxt info, action="hash()"
    return EMPTY_ROOT_HASH

proc getWithdrawals*(
    db: CoreDbRef;
    withdrawalsRoot: Hash256;
      ): seq[Withdrawal]
      {.gcsafe, raises: [RlpError].} =
  for encodedWd in db.getWithdrawalsData(withdrawalsRoot):
    result.add(rlp.decode(encodedWd, Withdrawal))

proc getBlockBody*(
    db: CoreDbRef;
    header: BlockHeader;
    output: var BlockBody;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  output.transactions = @[]
  output.uncles = @[]
  for encodedTx in db.getBlockTransactionData(header.txRoot):
    output.transactions.add(rlp.decode(encodedTx, Transaction))

  if header.withdrawalsRoot.isSome:
    output.withdrawals = some(db.getWithdrawals(header.withdrawalsRoot.get))

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.newKvt(Shared).get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt "getBlockBody()",
            ommersHash=header.ommersHash, action="get()", `error`=($$error)
        return false
    output.uncles = rlp.decode(encodedUncles, seq[BlockHeader])
  true

proc getBlockBody*(
    db: CoreDbRef;
    blockHash: Hash256;
    output: var BlockBody;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var header: BlockHeader
  if db.getBlockHeader(blockHash, header):
    return db.getBlockBody(header, output)

proc getBlockBody*(
    db: CoreDbRef;
    hash: Hash256;
      ): BlockBody
      {.gcsafe, raises: [RlpError,ValueError].} =
  if not db.getBlockBody(hash, result):
    raise newException(ValueError, "Error when retrieving block body")

proc getUncleHashes*(
    db: CoreDbRef;
    blockHashes: openArray[Hash256];
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError,ValueError].} =
  for blockHash in blockHashes:
    result &= db.getBlockBody(blockHash).uncles.mapIt(it.hash)

proc getUncleHashes*(
    db: CoreDbRef;
    header: BlockHeader;
      ): seq[Hash256]
      {.gcsafe, raises: [RlpError].} =
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let
      key = genericHashKey(header.ommersHash)
      encodedUncles = db.newKvt(Shared).get(key.toOpenArray).valueOr:
        if error.error == KvtNotFound:
          warn logTxt "getUncleHashes()",
            ommersHash=header.ommersHash, action="get()", `error`=($$error)
        return @[]
    return rlp.decode(encodedUncles, seq[BlockHeader]).mapIt(it.hash)

proc getTransactionKey*(
    db: CoreDbRef;
    transactionHash: Hash256;
      ): tuple[blockNumber: BlockNumber, index: int]
      {.gcsafe, raises: [RlpError].} =
  let
    txKey = transactionHashToBlockKey(transactionHash)
    tx = db.newKvt(Shared).get(txKey.toOpenArray).valueOr:
      if error.error == KvtNotFound:
        warn logTxt "getTransactionKey()",
          transactionHash, action="get()", `error`=($$error)
      return (0.toBlockNumber, -1)
  let key = rlp.decode(tx, TransactionKey)
  (key.blockNumber, key.index)

proc headerExists*(db: CoreDbRef; blockHash: Hash256): bool =
  ## Returns True if the header with the given block hash is in our DB.
  db.newKvt(Shared).hasKey(genericHashKey(blockHash).toOpenArray).valueOr:
    warn logTxt "headerExists()", blockHash, action="get()", `error`=($$error)
    return false

proc setHead*(
    db: CoreDbRef;
    blockHash: Hash256;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var header: BlockHeader
  if not db.getBlockHeader(blockHash, header):
    return false

  if not db.markCanonicalChain(header, blockHash):
    return false

  let canonicalHeadHash = canonicalHeadHashKey()
  db.newKvt.put(canonicalHeadHash.toOpenArray, rlp.encode(blockHash)).isOkOr:
    warn logTxt "setHead()", canonicalHeadHash, action="put()", error=($$error)
  return true

proc setHead*(
    db: CoreDbRef;
    header: BlockHeader;
    writeHeader = false;
      ): bool
      {.gcsafe, raises: [RlpError].} =
  var headerHash = rlpHash(header)
  let kvt = db.newKvt()
  if writeHeader:
    kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
      warn logTxt "setHead()", headerHash, action="put()", error=($$error)
      return false
  if not db.markCanonicalChain(header, headerHash):
    return false
  let canonicalHeadHash = canonicalHeadHashKey()
  kvt.put(canonicalHeadHash.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "setHead()", canonicalHeadHash, action="put()", error=($$error)
    return false
  true

proc persistReceipts*(
    db: CoreDbRef;
    receipts: openArray[Receipt];
      ): Hash256 =
  const info = "persistReceipts()"
  let mpt = db.newMpt()
  for idx, rec in receipts:
    mpt.merge(rlp.encode(idx), rlp.encode(rec)).isOkOr:
      warn logTxt info, idx, action="merge()", error=($$error)
  mpt.rootVid.hash(update=true).valueOr:
    warn logTxt info, action="hash()"
    return EMPTY_ROOT_HASH

proc getReceipts*(
    db: CoreDbRef;
    receiptRoot: Hash256;
      ): seq[Receipt]
      {.gcsafe, raises: [RlpError].} =
  var receipts = newSeq[Receipt]()
  for r in db.getReceipts(receiptRoot):
    receipts.add(r)
  return receipts

proc persistHeaderToDb*(
    db: CoreDbRef;
    header: BlockHeader;
    forceCanonical: bool;
    startOfHistory = GENESIS_PARENT_HASH;
      ): seq[BlockHeader]
      {.gcsafe, raises: [RlpError,EVMError].} =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  if not isStartOfHistory and not db.headerExists(header.parentHash):
    raise newException(ParentNotFound, "Cannot persist block header " &
        $headerHash & " with unknown parent " & $header.parentHash)
  let kvt = db.newKvt()
  kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
    warn logTxt "persistHeaderToDb()",
      headerHash, action="put()", `error`=($$error)
    return @[]

  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty
  let scoreKey = blockHashToScoreKey(headerHash)
  kvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn logTxt "persistHeaderToDb()",
      scoreKey, action="put()", `error`=($$error)
    return @[]

  db.addBlockNumberToHashLookup(header)

  var canonHeader: BlockHeader
  if not db.getCanonicalHead canonHeader:
    return db.setAsCanonicalChainHead(headerHash)

  let headScore = db.getScore(canonHeader.hash)
  if score > headScore or forceCanonical:
    return db.setAsCanonicalChainHead(headerHash)

proc persistHeaderToDbWithoutSetHead*(
    db: CoreDbRef;
    header: BlockHeader;
    startOfHistory = GENESIS_PARENT_HASH;
      ) {.gcsafe, raises: [RlpError].} =
  let isStartOfHistory = header.parentHash == startOfHistory
  let headerHash = header.blockHash
  let score = if isStartOfHistory: header.difficulty
              else: db.getScore(header.parentHash) + header.difficulty
  let
    kvt = db.newKvt()
    scoreKey = blockHashToScoreKey(headerHash)
  kvt.put(scoreKey.toOpenArray, rlp.encode(score)).isOkOr:
    warn logTxt "persistHeaderToDbWithoutSetHead()",
      scoreKey, action="put()", `error`=($$error)
    return
  kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
    warn logTxt "persistHeaderToDbWithoutSetHead()",
      headerHash, action="put()", `error`=($$error)
    return

# FIXME-Adam: This seems like a bad idea. I don't see a way to get the score
# in stateless mode, but it seems dangerous to just shove the header into
# the DB *without* also storing the score.
proc persistHeaderToDbWithoutSetHeadOrScore*(db: CoreDbRef; header: BlockHeader) =
  db.addBlockNumberToHashLookup(header)
  let
    kvt = db.newKvt()
    blockHash = header.blockHash
  kvt.put(genericHashKey(blockHash).toOpenArray, rlp.encode(header)).isOkOr:
    warn logTxt "persistHeaderToDbWithoutSetHeadOrScore()",
      blockHash, action="put()", `error`=($$error)
    return

proc persistUncles*(db: CoreDbRef, uncles: openArray[BlockHeader]): Hash256 =
  ## Persists the list of uncles to the database.
  ## Returns the uncles hash.
  let enc = rlp.encode(uncles)
  result = keccakHash(enc)
  db.newKvt.put(genericHashKey(result).toOpenArray, enc).isOkOr:
    warn logTxt "persistUncles()",
      unclesHash=result, action="put()", `error`=($$error)
    return EMPTY_ROOT_HASH


proc safeHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  discard db.getHash(safeHashKey(), result)

proc safeHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  let safeHashKey = safeHashKey()
  db.newKvt.put(safeHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "safeHeaderHash()",
      safeHashKey, action="put()", `error`=($$error)
    return

proc finalizedHeaderHash*(
    db: CoreDbRef;
      ): Hash256
      {.gcsafe, raises: [RlpError].} =
  discard db.getHash(finalizedHashKey(), result)

proc finalizedHeaderHash*(db: CoreDbRef, headerHash: Hash256) =
  let finalizedHashKey = finalizedHashKey()
  db.newKvt.put(finalizedHashKey.toOpenArray, rlp.encode(headerHash)).isOkOr:
    warn logTxt "finalizedHeaderHash()",
      finalizedHashKey, action="put()", `error`=($$error)
    return

proc safeHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  db.getBlockHeader(db.safeHeaderHash)

proc finalizedHeader*(
    db: CoreDbRef;
      ): BlockHeader
      {.gcsafe, raises: [RlpError,BlockNotFound].} =
  db.getBlockHeader(db.finalizedHeaderHash)

proc haveBlockAndState*(db: CoreDbRef, headerHash: Hash256): bool =
  var header: BlockHeader
  if not db.getBlockHeader(headerHash, header):
    return false
  # see if stateRoot exists
  db.exists(header.stateRoot)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
