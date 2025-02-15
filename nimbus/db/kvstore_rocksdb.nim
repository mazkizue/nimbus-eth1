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
  std/os,
  rocksdb, stew/results,
  eth/db/kvstore

export results, kvstore

const maxOpenFiles = 512

type
  RocksStoreRef* = ref object of RootObj
    store*: RocksDBInstance
    tmpDir*: string

proc get*(db: RocksStoreRef, key: openArray[byte], onData: kvstore.DataProc): KvResult[bool] =
  db.store.get(key, onData)

proc find*(db: RocksStoreRef, prefix: openArray[byte], onFind: kvstore.KeyValueProc): KvResult[int] =
  raiseAssert "Unimplemented"

proc put*(db: RocksStoreRef, key, value: openArray[byte]): KvResult[void] =
  db.store.put(key, value)

proc contains*(db: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  db.store.contains(key)

proc del*(db: RocksStoreRef, key: openArray[byte]): KvResult[bool] =
  db.store.del(key)

proc clear*(db: RocksStoreRef): KvResult[bool] =
  db.store.clear()

proc close*(db: RocksStoreRef) =
  db.store.close

proc init*(
    T: type RocksStoreRef, basePath: string, name: string,
    readOnly = false): KvResult[T] =
  let
    dataDir = basePath / name / "data"
    # tmpDir = basePath / name / "tmp" -- notused
    backupsDir = basePath / name / "backups"

  try:
    createDir(dataDir)
    createDir(backupsDir)
  except OSError, IOError:
    return err("rocksdb: cannot create database directory")

  var store: RocksDBInstance
  if (let v = store.init(
      dataDir, backupsDir, readOnly, maxOpenFiles = maxOpenFiles); v.isErr):
    return err(v.error)

  ok(T(store: store))
