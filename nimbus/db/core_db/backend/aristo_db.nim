# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  results,
  "../.."/[aristo, aristo/aristo_desc, aristo/aristo_init/memory_only],
  "../.."/[kvt, kvt/kvt_desc, kvt/kvt_init/memory_only],
  ".."/[base, base/base_desc],
  ./aristo_db/[common_desc, handlers_aristo, handlers_kvt]

# Annotation helpers
{.pragma:  noRaise, gcsafe, raises: [].}
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

export
  AristoApiRlpError,
  AristoCoreDbKvtBE,
  memory_only

type
  AristoCoreDbRef* = ref object of CoreDbRef
    ## Main descriptor
    kdbBase: KvtBaseRef                      ## Kvt subsystem
    adbBase: AristoBaseRef                   ## Aristo subsystem

  AristoCoreDbBE = ref object of CoreDbBackendRef

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template valueOrApiError[U,V](rc: Result[U,V]; info: static[string]): U =
  rc.valueOr: raise (ref AristoApiRlpError)(msg: info)

func notImplemented[T](
    _: typedesc[T];
    db: AristoCoreDbRef;
    info: string;
      ): CoreDbRc[T] {.gcsafe.} =
  ## Applies only to `Aristo` methods
  err((VertexID(0),aristo.NotImplemented).toError(db, info))

# ------------------------------------------------------------------------------
# Private call back functions (too large for embedding to maintain)
# ------------------------------------------------------------------------------

iterator kvtPairs(
    T: typedesc;
    dsc: CoreDxKvtRef;
    info: static[string];
      ): (Blob,Blob) =
  let p = dsc.kvt.forkTop.valueOrApiError info
  defer: discard p.forget()

  dsc.methods.pairsIt = iterator(): (Blob, Blob) =
    for (n,k,v) in T.walkPairs p:
      yield (k,v)


iterator mptReplicate(
    T: typedesc;
    dsc: CoreDxMptRef;
    info: static[string];
      ): (Blob,Blob)
      {.rlpRaise.} =
  let p = dsc.mpt.forkTop.valueOrApiError info
  defer: discard p.forget()

  let root = dsc.root
  for (vid,key,vtx,node) in T.replicate p:
    if key.len == 32:
      yield (@key, node.encode)
    elif vid == root:
      yield (@(key.to(Hash256).data), node.encode)

# ------------------------------------------------------------------------------
# Private tx and base methods
# ------------------------------------------------------------------------------

proc txMethods(
    db: AristoCoreDbRef;
    aTx: AristoTxRef;
    kTx: KvtTxRef;
     ): CoreDbTxFns =
  ## To be constructed by some `CoreDbBaseFns` function
  CoreDbTxFns(
    levelFn: proc(): int =
      aTx.level,

    commitFn: proc(ignore: bool): CoreDbRc[void] =
      const info = "commitFn()"
      ? aTx.commit.toVoidRc(db, info)
      ? kTx.commit.toVoidRc(db, info)
      ok(),

    rollbackFn: proc(): CoreDbRc[void] =
      const info = "rollbackFn()"
      ? aTx.rollback.toVoidRc(db, info)
      ? kTx.rollback.toVoidRc(db, info)
      ok(),

    disposeFn: proc(): CoreDbRc[void] =
      const info =  "disposeFn()"
      if aTx.isTop: ? aTx.rollback.toVoidRc(db, info)
      if kTx.isTop: ? kTx.rollback.toVoidRc(db, info)
      ok(),

    safeDisposeFn: proc(): CoreDbRc[void] =
      const info =  "safeDisposeFn()"
      if aTx.isTop: ? aTx.rollback.toVoidRc(db, info)
      if kTx.isTop: ? kTx.rollback.toVoidRc(db, info)
      ok())


proc baseMethods(
    db: AristoCoreDbRef;
    A:  typedesc;
    K:  typedesc;
      ): CoreDbBaseFns =
  let db = db
  CoreDbBaseFns(
    backendFn: proc(): CoreDbBackendRef =
      db.bless(AristoCoreDbBE()),

    destroyFn: proc(flush: bool) =
      db.adbBase.destroy(flush)
      db.kdbBase.destroy(flush),

    levelFn: proc(): int =
      db.adbBase.getLevel,

    vidHashFn: proc(vid: CoreDbVidRef; update: bool): CoreDbRc[Hash256] =
      db.adbBase.getHash(vid, update, "vidHashFn()"),

    errorPrintFn: proc(e: CoreDbErrorRef): string =
      e.errorPrint(),

    legacySetupFn: proc() =
      discard,

    getRootFn: proc(root: Hash256; createOk: bool): CoreDbRc[CoreDbVidRef] =
      db.adbBase.getVid(root, createOk, "getRootFn()"),

    newKvtFn: proc(saveMode: CoreDbSaveFlags): CoreDbRc[CoreDxKvtRef] =
      db.kdbBase.gc()
      let dsc = ? db.kdbBase.newKvtHandler(saveMode, "newKvtFn()")
      when K is MemBackendRef:
        dsc.methods.pairsIt = iterator(): (Blob, Blob) =
          for (n,k,v) in K.kvtPairs dsc:
            yield (k,v)
      ok(dsc),

    newMptFn: proc(
        root: CoreDbVidRef;
        prune: bool; # ignored
        saveMode: CoreDbSaveFlags;
          ): CoreDbRc[CoreDxMptRef] =
      db.kdbBase.gc()
      let dsc = ? db.adbBase.newMptHandler(root, saveMode, "newMptFn()")
      when K is MemBackendRef:
        dsc.methods.replicateIt = iterator: (Blob,Blob) {.rlpRaise.} =
          for w in T.mptReplicate(dsc, "forkTop() for replicateIt()"):
            yield w
      ok(dsc),

    newAccFn: proc(
        root: CoreDbVidRef;
        prune: bool; # ignored
        saveMode: CoreDbSaveFlags;
          ): CoreDbRc[CoreDxAccRef] =
      db.kdbBase.gc()
      ok(? db.adbBase.newAccHandler(root, saveMode, "newAccFn()")),

    beginFn: proc(): CoreDbRc[CoreDxTxRef] =
      const info = "beginFn()"
      let
        aTx = ? db.adbBase.txBegin(info)
        kTx = ? db.kdbBase.txBegin(info)
      ok(db.bless CoreDxTxRef(methods: db.txMethods(aTx, kTx))),

    getIdFn: proc(): CoreDbRc[CoreDxTxID] =
      CoreDxTxID.notImplemented(db, "getIdFn()"),

    captureFn: proc(flags: set[CoreDbCaptFlags]): CoreDbRc[CoreDxCaptRef] =
      CoreDxCaptRef.notImplemented(db, "capture()"))

# ------------------------------------------------------------------------------
# Private  constructor helpers
# ------------------------------------------------------------------------------

proc create(
    dbType: CoreDbType;
    kdb: KvtDbRef;
    K: typedesc;
    adb: AristoDbRef;
    A: typedesc;
      ): CoreDbRef =
  ## Constructor helper

  # Local extensions
  var db = AristoCoreDbRef()
  db.adbBase = AristoBaseRef.init(db, adb)
  db.kdbBase = KvtBaseRef.init(db, kdb)

  # Base descriptor
  db.dbType = dbType
  db.methods = db.baseMethods(A,K)
  db.bless

proc init(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    qlr: QidLayoutRef;
      ): CoreDbRef =
  dbType.create(KvtDbRef.init(K), K, AristoDbRef.init(A, qlr), A)

proc init(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
      ): CoreDbRef =
  dbType.create(KvtDbRef.init(K), K, AristoDbRef.init(A), A)

# ------------------------------------------------------------------------------
# Public constructor helpers
# ------------------------------------------------------------------------------

proc init*(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    path: string;
    qlr: QidLayoutRef;
      ): CoreDbRef =
  dbType.create(
    KvtDbRef.init(K, path).expect "Kvt/RocksDB init() failed", K,
    AristoDbRef.init(A, path, qlr).expect "Aristo/RocksDB init() failed", A)

proc init*(
    dbType: CoreDbType;
    K: typedesc;
    A: typedesc;
    path: string;
      ): CoreDbRef =
  dbType.create(
    KvtDbRef.init(K, path).expect "Kvt/RocksDB init() failed", K,
    AristoDbRef.init(A, path).expect "Aristo/RocksDB init() failed", A)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newAristoMemoryCoreDbRef*(qlr: QidLayoutRef): CoreDbRef =
  AristoDbMemory.init(kvt.MemBackendRef, aristo.MemBackendRef, qlr)

proc newAristoMemoryCoreDbRef*(): CoreDbRef =
  AristoDbMemory.init(kvt.MemBackendRef, aristo.MemBackendRef)

proc newAristoVoidCoreDbRef*(): CoreDbRef =
  AristoDbVoid.init(kvt.VoidBackendRef, aristo.VoidBackendRef)

# ------------------------------------------------------------------------------
# Public helpers for direct backend access
# ------------------------------------------------------------------------------

func toAristo*(be: CoreDbKvtBackendRef): KvtDbRef =
  if be.parent.isAristo:
    return be.AristoCoreDbKvtBE.kdb

func toAristo*(be: CoreDbMptBackendRef): AristoDbRef =
  if be.parent.isAristo:
    return be.AristoCoreDbMptBE.adb

func toAristo*(be: CoreDbAccBackendRef): AristoDbRef =
  if be.parent.isAristo:
    return be.AristoCoreDbAccBE.adb

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
