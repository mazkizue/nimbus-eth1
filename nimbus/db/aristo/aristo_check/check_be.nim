# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, tables],
  eth/[common, trie/nibbles],
  stew/interval_set,
  ../../aristo,
  ../aristo_walk/persistent,
  ".."/[aristo_desc, aristo_get, aristo_vid]

const
  Vid2 = @[VertexID(2)].toHashSet

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc invTo(s: IntervalSetRef[VertexID,uint64]; T: type HashSet[VertexID]): T =
  ## Convert the complement of the argument list `s` to a set of vertex IDs
  ## as it would appear with a vertex generator state list.
  if s.total < high(uint64):
    for w in s.increasing:
      if w.maxPt == high(VertexID):
        result.incl w.minPt # last interval
      else:
        for pt in w.minPt .. w.maxPt:
          result.incl pt

proc toNodeBE(
    vtx: VertexRef;                    # Vertex to convert
    db: AristoDbRef;                   # Database, top layer
      ): Result[NodeRef,VertexID] =
  ## Similar to `toNode()` but fetching from the backend only
  case vtx.vType:
  of Leaf:
    let node = NodeRef(vType: Leaf, lPfx: vtx.lPfx, lData: vtx.lData)
    if vtx.lData.pType == AccountData:
      let vid = vtx.lData.account.storageID
      if vid.isValid:
        let rc = db.getKeyBE vid
        if rc.isErr or not rc.value.isValid:
          return err(vid)
        node.key[0] = rc.value
    return ok node
  of Branch:
    let node = NodeRef(vType: Branch, bVid: vtx.bVid)
    var missing: seq[VertexID]
    for n in 0 .. 15:
      let vid = vtx.bVid[n]
      if vid.isValid:
        let rc = db.getKeyBE vid
        if rc.isOk and rc.value.isValid:
          node.key[n] = rc.value
        else:
          return err(vid)
      else:
        node.key[n] = VOID_HASH_KEY
    return ok node
  of Extension:
    let
      vid = vtx.eVid
      rc = db.getKeyBE vid
    if rc.isOk and rc.value.isValid:
      let node = NodeRef(vType: Extension, ePfx: vtx.ePfx, eVid: vid)
      node.key[0] = rc.value
      return ok node
    return err(vid)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkBE*[T: RdbBackendRef|MemBackendRef|VoidBackendRef](
    _: type T;
    db: AristoDbRef;                   # Database, top layer
    relax: bool;                       # Not compiling hashes if `true`
    cache: bool;                       # Also verify against top layer cache
    fifos = true;                      # Also verify cascaded filter fifos
      ): Result[void,(VertexID,AristoError)] =
  ## Make sure that each vertex has a Merkle hash and vice versa. Also check
  ## the vertex ID generator state.
  let vids = IntervalSetRef[VertexID,uint64].init()
  discard vids.merge Interval[VertexID,uint64].new(VertexID(1),high(VertexID))

  for (_,vid,vtx) in T.walkVtxBE db:
    if not vtx.isValid:
      return err((vid,CheckBeVtxInvalid))
    let rc = db.getKeyBE vid
    if rc.isErr or not rc.value.isValid:
      return err((vid,CheckBeKeyMissing))
    case vtx.vType:
    of Leaf:
      discard
    of Branch:
      block check42Links:
        var seen = false
        for n in 0 .. 15:
          if vtx.bVid[n].isValid:
            if seen:
              break check42Links
            seen = true
        return err((vid,CheckBeVtxBranchLinksMissing))
    of Extension:
      if vtx.ePfx.len == 0:
        return err((vid,CheckBeVtxExtPfxMissing))

  for (_,vid,key) in T.walkKeyBE db:
    if not key.isvalid:
      return err((vid,CheckBeKeyInvalid))
    let vtx = db.getVtxBE(vid).valueOr:
      return err((vid,CheckBeVtxMissing))
    let node = vtx.toNodeBE(db).valueOr: # backend links only
      return err((vid,CheckBeKeyCantCompile))
    if not relax:
      let expected = node.digestTo(HashKey)
      if expected != key:
        return err((vid,CheckBeKeyMismatch))
    discard vids.reduce Interval[VertexID,uint64].new(vid,vid)

  # Compare calculated state against database state
  block:
    # Extract vertex ID generator state
    let vGen = block:
      let rc = db.getIdgBE()
      if rc.isOk:
        rc.value.toHashSet
      elif rc.error == GetIdgNotFound:
        EmptyVidSeq.toHashSet
      else:
        return err((VertexID(0),rc.error))
    let
      vGenExpected = vids.invTo(HashSet[VertexID])
      delta = vGenExpected -+- vGen # symmetric difference
    if 0 < delta.len:
      # Exclude fringe case when there is a single root vertex only
      if vGenExpected != Vid2 or 0 < vGen.len:
        return err((delta.toSeq.sorted[^1],CheckBeGarbledVGen))

  # Check top layer cache against backend
  if cache:
    if db.top.dirty:
      return err((VertexID(0),CheckBeCacheIsDirty))

    # Check structural table
    for (vid,vtx) in db.top.sTab.pairs:
      # A `kMap[]` entry must exist.
      if not db.top.kMap.hasKey vid:
        return err((vid,CheckBeCacheKeyMissing))
      if vtx.isValid:
        # Register existing vid against backend generator state
        discard vids.reduce Interval[VertexID,uint64].new(vid,vid)
      else:
        # Some vertex is to be deleted, the key must be empty
        let lbl = db.top.kMap.getOrVoid vid
        if lbl.isValid:
          return err((vid,CheckBeCacheKeyNonEmpty))
        # There must be a representation on the backend DB
        if db.getVtxBE(vid).isErr:
          return err((vid,CheckBeCacheVidUnsynced))
        # Register deleted vid against backend generator state
        discard vids.merge Interval[VertexID,uint64].new(vid,vid)

    # Check cascaded fifos
    if fifos and
       not db.backend.isNil and
       not db.backend.filters.isNil:
      var lastTrg = db.getKeyUBE(VertexID(1)).get(otherwise = VOID_HASH_KEY)
                      .to(Hash256)
      for (qid,filter) in db.backend.T.walkFifoBe: # walk in fifo order
        if filter.src != lastTrg:
          return err((VertexID(0),CheckBeFifoSrcTrgMismatch))
        if filter.trg != filter.kMap.getOrVoid(VertexID 1).to(Hash256):
          return err((VertexID(1),CheckBeFifoTrgNotStateRoot))
        lastTrg = filter.trg

    # Check key table
    var list: seq[VertexID]
    for (vid,lbl) in db.top.kMap.pairs:
      list.add vid
      let vtx = db.getVtx vid
      if not db.top.sTab.hasKey(vid) and not vtx.isValid:
        return err((vid,CheckBeCacheKeyDangling))
      if not lbl.isValid or relax:
        continue
      if not vtx.isValid:
        return err((vid,CheckBeCacheVtxDangling))
      let node = vtx.toNode(db).valueOr: # compile cache first
        return err((vid,CheckBeCacheKeyCantCompile))
      let expected = node.digestTo(HashKey)
      if expected != lbl.key:
        return err((vid,CheckBeCacheKeyMismatch))

    # Check vGen
    let
      vGen = db.top.vGen.vidReorg.toHashSet
      vGenExpected = vids.invTo(HashSet[VertexID])
      delta = vGenExpected -+- vGen # symmetric difference
    if 0 < delta.len:
      # Exclude fringe case when there is a single root vertex only
      if vGenExpected != Vid2 or 0 < vGen.len:
        let delta = delta.toSeq
        # As happens with Merkle signature calculator: `root=VertexID(2)`
        if delta.len != 1 or delta[0] != VertexID(1) or VertexID(1) in vGen:
          return err((delta.sorted[^1],CheckBeCacheGarbledVGen))

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
