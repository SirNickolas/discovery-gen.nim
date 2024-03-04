from   std/enumerate import enumerate
from   std/dirs import nil
from   std/paths import `/`, Path, parentDir
import std/sets
import std/tables
import jsony
from   kdl/types import KdlError
from   kdl/parser import parseKdlFile
import questionable
from   sourcegens/codegens import run
from   sourcegens/emission import initEmitter
from   sourcegens/overridableTables import `[]`, toOverridableOrderedTable, values
from   ./discoveryGen/backends import newTargetConfig
from   ./discoveryGen/backends/d import initDTarget
import ./discoveryGen/configuration
import ./discoveryGen/discovery
from   ./discoveryGen/rawConfigLoading import loadRawConfig

type
  HashSetPatchMode* = enum
    hspmAllBut, hspmOnly

  HashSetPatch*[T] = object
    mode*: HashSetPatchMode
    elems*: HashSet[T]

  DiscoveryGenError* = object of CatchableError

let defaultBackends = {
  "d": initDTarget,
}.toOverridableOrderedTable '#'

proc readSchemas(cfg: Config): seq[DiscoveryRestDescription] =
  for api in cfg.apis.values:
    # TODO: Handle `api.settings.schema.isNone`.
    result &=
      readFile(string cfg.apiRoot / api.settings.schema.unsafeGet)
      .fromJson DiscoveryRestDescription

template changeCurrentDir(path: Path) =
  let prev = paths.getCurrentDir()
  dirs.setCurrentDir path
  defer: dirs.setCurrentDir prev

proc genDiscoveryApis*(
  cfg: Config; apis = default HashSetPatch[string]; targets = default HashSetPatch[string];
) =
  # TODO: Respect `apis`.
  let schemas = cfg.readSchemas

  dirs.createDir cfg.targetRoot
  changeCurrentDir cfg.targetRoot

  for apiIndex, apiId in enumerate cfg.apis.keys:
    # TODO: Respect `targets`.
    for target in cfg.targets.values:
      let cgt = defaultBackends[target.backend]:
        newTargetConfig(schemas[apiIndex], target.getSettingsForApi apiId)
      for spec in cgt.values:
        dirs.createDir spec.path.Path.parentDir
        var f = open(spec.path, fmWrite)
        defer: f.close
        var emitter = initEmitter(spec.binary, spec.indent) do (chunk: openArray[char]):
          let n = f.writeChars(chunk, 0, chunk.len)
          if n != chunk.len:
            raise newException(IoError, "Failed to write to " & spec.path)
        spec.codegen.run emitter

proc genDiscoveryApis*(
  configPath: Path;
  apiRoot = none Path;
  targetRoot = none Path;
  apis = default HashSetPatch[string];
  targets = default HashSetPatch[string];
) =
  var cfg = block:
    let doc =
      try:
        parseKdlFile configPath.string
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

  if apiRoot =? apiRoot:
    cfg.apiRoot = apiRoot
  if targetRoot =? targetRoot:
    cfg.targetRoot = targetRoot

  cfg.genDiscoveryApis(apis, targets)
