import std/options
import std/sets
from   kdl/types import KdlError
from   kdl/parser import parseKdlFile
import ./discoveryGen/configLoading
from   ./discoveryGen/rawConfigLoading import loadRawConfig

type
  HashSetPatchMode* = enum
    hspmAllBut, hspmOnly

  HashSetPatch*[T] = object
    mode*: HashSetPatchMode
    elems*: HashSet[T]

  DiscoveryGenError* = object of CatchableError

proc genDiscoveryApis*(
  cfg: Config; apis = default HashSetPatch[string]; targets = default HashSetPatch[string];
) =
  echo cfg, '\n', apis, '\n', targets

proc genDiscoveryApis*(
  configPath: string;
  apiRoot = none string;
  targetRoot = none string;
  apis = default HashSetPatch[string];
  targets = default HashSetPatch[string];
) =
  var cfg = block:
    let doc =
      try:
        parseKdlFile configPath
      except KdlError as e:
        raise newException(DiscoveryGenError, "KDL parsing error: " & e.msg, e)
    try:
      doc.loadRawConfig.convertRawConfig
    except KdlDeserializationError as e:
      var report = e.msg & ':'
      for msg in e.errors:
        report &= "\n  "
        report &= msg
      raise newException(DiscoveryGenError, report, e)

  if apiRoot.isSome:
    cfg.apiRoot = apiRoot.unsafeGet
  if targetRoot.isSome:
    cfg.targetRoot = targetRoot.unsafeGet

  genDiscoveryApis(cfg, apis, targets)
