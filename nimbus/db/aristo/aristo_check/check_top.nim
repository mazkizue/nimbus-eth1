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
  std/[sequtils, sets, tables],
  eth/[common, trie/nibbles],
  results,
  ".."/[aristo_desc, aristo_get, aristo_serialise, aristo_utils]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkTopStrict*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  for (vid,vtx) in db.top.sTab.pairs:
    if vtx.isValid:
      let node = vtx.toNode(db).valueOr:
        return err((vid,CheckStkVtxIncomplete))

      let lbl = db.top.kMap.getOrVoid vid
      if not lbl.isValid:
        return err((vid,CheckStkVtxKeyMissing))
      if lbl.key != node.digestTo(HashKey):
        return err((vid,CheckStkVtxKeyMismatch))

      let revVids = db.top.pAmk.getOrVoid lbl
      if not revVids.isValid:
        return err((vid,CheckStkRevKeyMissing))
      if vid notin revVids:
        return err((vid,CheckStkRevKeyMismatch))

  let
    pAmkVtxCount = db.top.pAmk.values.toSeq.foldl(a + b.len, 0)
    sTabVtxCount = db.top.sTab.values.toSeq.filterIt(it.isValid).len
  # Non-zero values mist sum up the same
  if pAmkVtxCount < sTabVtxCount:
    return err((VertexID(0),CheckStkVtxCountMismatch))

  ok()


proc checkTopRelaxed*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  if 0 < db.top.pPrf.len:
    for vid in db.top.pPrf:
      let vtx = db.top.sTab.getOrVoid vid
      if vtx.isValid:
        let node = vtx.toNode(db).valueOr:
          return err((vid,CheckRlxVtxIncomplete))

        let lbl = db.top.kMap.getOrVoid vid
        if not lbl.isValid:
          return err((vid,CheckRlxVtxKeyMissing))
        if lbl.key != node.digestTo(HashKey):
          return err((vid,CheckRlxVtxKeyMismatch))

        let revVids = db.top.pAmk.getOrVoid lbl
        if not revVids.isValid:
          return err((vid,CheckRlxRevKeyMissing))
        if vid notin revVids:
          return err((vid,CheckRlxRevKeyMismatch))
  else:
    for (vid,lbl) in db.top.kMap.pairs:
      if lbl.isValid:                              # Otherwise to be deleted
        let vtx = db.getVtx vid
        if vtx.isValid:
          let node = vtx.toNode(db).valueOr:
            continue
          if lbl.key != node.digestTo(HashKey):
            return err((vid,CheckRlxVtxKeyMismatch))

          let revVids = db.top.pAmk.getOrVoid lbl
          if not revVids.isValid:
            return err((vid,CheckRlxRevKeyMissing))
          if vid notin revVids:
            return err((vid,CheckRlxRevKeyMismatch))
  ok()


proc checkTopCommon*(
    db: AristoDbRef;                   # Database, top layer
      ): Result[void,(VertexID,AristoError)] =
  # Some `kMap[]` entries may ne void indicating backend deletion
  let
    kMapCount = db.top.kMap.values.toSeq.filterIt(it.isValid).len
    kMapNilCount = db.top.kMap.len - kMapCount

  # Collect leafs and check deleted entries
  var
    nNilVtx = 0
    leafs = db.top.lTab.values.toSeq.filterIt(it.isValid).toHashSet
  for (vid,vtx) in db.top.sTab.pairs:
    if vtx.isValid:
      case vtx.vType:
      of Leaf:
        if vid notin leafs:
          return err((vid,CheckAnyLeafUnregistered))
        leafs.excl vid
      of Branch:
        block check42Links:
          var seen = false
          for n in 0 .. 15:
            if vtx.bVid[n].isValid:
              if seen:
                break check42Links
              seen = true
          return err((vid,CheckAnyVtxBranchLinksMissing))
      of Extension:
        if vtx.ePfx.len == 0:
          return err((vid,CheckAnyVtxExtPfxMissing))
    else:
      nNilVtx.inc
      discard db.getVtxBE(vid).valueOr:
        return err((vid,CheckAnyVidVtxMissing))
      if not db.top.kMap.hasKey vid:
        return err((vid,CheckAnyVtxEmptyKeyMissing))
      if db.top.kMap.getOrVoid(vid).isValid:
        return err((vid,CheckAnyVtxEmptyKeyExpected))

  # Check for dangling leaf records
  if 0 < leafs.len:
    return err((leafs.toSeq[0],CheckAnyLeafVidDangling))

  # If present, there are at least as many deleted hashes as there are deleted
  # vertices.
  if kMapNilCount != 0 and kMapNilCount < nNilVtx:
    return err((VertexID(0),CheckAnyVtxEmptyKeyMismatch))

  let pAmkVtxCount = db.top.pAmk.values.toSeq.foldl(a + b.len, 0)
  if pAmkVtxCount != kMapCount:
    var knownKeys: HashSet[VertexID]
    for (key,vids) in db.top.pAmk.pairs:
      for vid in vids:
        if not db.top.kMap.hasKey(vid):
          return err((vid,CheckAnyRevVtxMissing))
        if vid in knownKeys:
          return err((vid,CheckAnyRevVtxDup))
        knownKeys.incl vid
    return err((VertexID(0),CheckAnyRevCountMismatch)) # should not apply(!)

  for vid in db.top.pPrf:
    if not db.top.kMap.hasKey(vid):
      return err((vid,CheckAnyVtxLockWithoutKey))
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

