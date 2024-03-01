import std/options
from   std/paths import `/`, Path
import std/sets
import std/tables
import jsony
from   kdl/types import KdlError
from   kdl/parser import parseKdlFile
import ./discoveryGen/configLoading
import ./discoveryGen/discovery
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
  for api in cfg.apis.values:
    let json = block:
      var f = open string cfg.apiRoot.Path / api.settings.discoveryPath.get.Path
      defer: f.close
      f.readAll
    let schema = json.fromJson DiscoveryRestDescription
    echo schema

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
