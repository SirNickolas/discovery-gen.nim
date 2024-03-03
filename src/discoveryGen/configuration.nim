import std/options
from   std/paths import Path
import std/sets
import std/strformat
import std/tables
import ./rawConfigLoading

export KdlDeserializationError, KdlDoc

type
  ApiSettings* = object
    discoveryPath*: Option[Path]

  Api* = ref object
    id*: string
    settings*: ApiSettings
    overrides*: Table[string, ref ApiSettings]

  Target* = ref object
    id*, lang*: string
    settings*: KdlDoc
    overrides*: Table[string, ref KdlDoc]

  Config* = object
    strict*: bool
    apiRoot*, targetRoot*: Path
    apis*: Table[string, Api]
    targets*: Table[string, Target]

  Context = object
    declaredApis, declaredTargets: HashSet[string]
    selectedApis: seq[Api]
    errors: seq[string]

  Quoted = distinct string

proc formatValue(s: var string; val: Quoted; _: string) =
  s.addQuoted val.string

proc getOrNew[K; V](t: var Table[K, ref V]; key: K): ref V =
  let p = addr t.mgetOrPut(key, nil)
  result = p[]
  if result == nil:
    new p[]
    result = p[]

template getOrNew[K](t: var Table[K, ref auto]; key: K; val, body1, body2: untyped): untyped =
  let p = addr t.mgetOrPut(key, nil)
  if (let val = p[]; val != nil):
    body1
  else:
    new p[]
    let val {.used.} = p[]
    body2

proc convertApi(c: var Context; cfg: var Config; rawApi: sink RawApi) =
  if rawApi.ids.len == 1:
    c.declaredApis.incl rawApi.ids[0]

  c.selectedApis.setLen 0
  for id in rawApi.ids.mitems:
    c.selectedApis.add cfg.apis.getOrNew(id, api) do:
      api
    do:
      api.id = move id
      api

  if rawApi.discovery.isSome:
    for api in c.selectedApis:
      api.settings.discoveryPath = rawApi.discovery

  for rawOverride in rawApi.overrides.mitems:
    let settings = (ref ApiSettings)(discoveryPath: move rawOverride.discovery)
    for id in rawOverride.targets:
      discard cfg.targets.getOrNew id
      for api in c.selectedApis:
        if api.overrides.hasKeyOrPut(id, settings):
          c.errors &= &"API {Quoted api.id} has multiple overrides for target {Quoted id}."

proc convertTarget(c: var Context; cfg: var Config; rawTarget: sink RawTarget) =
  if c.declaredTargets.containsOrIncl rawTarget.id:
    c.errors &= &"Duplicate target {Quoted rawTarget.id}."

  let target = cfg.targets.getOrNew rawTarget.id
  target.id = move rawTarget.id
  if rawTarget.lang.isSome:
    target.lang = move rawTarget.lang.get
  else:
    # TODO: Try to check that during deserialization.
    c.errors &= &"Target {Quoted target.id} is missing lang= property."

  target.settings = move rawTarget.settings
  for rawOverride in rawTarget.overrides.mitems:
    let settings = new KdlDoc
    settings[] = move rawOverride.settings
    for id in rawOverride.ids:
      if target.overrides.hasKeyOrPut(id, settings):
        c.errors &= &"Target {Quoted target.id} has multiple overrides for API {Quoted id}."
      else:
        discard cfg.apis.hasKeyOrPut(id, nil)

proc convertRawConfig*(raw: sink RawConfig): Config =
  var c: Context
  result.strict = raw.strict
  result.apiRoot = move raw.apiRoot
  result.targetRoot = move raw.targetRoot

  for rawApi in raw.apis.mitems:
    c.convertApi result, move rawApi

  for rawTarget in raw.targets.mitems:
    c.convertTarget result, move rawTarget

  if result.apis.len != c.declaredApis.len:
    for id, api in result.apis:
      if id not_in c.declaredApis:
        c.errors &= &"API {Quoted id} does not have its dedicated entry."

  if result.targets.len != c.declaredTargets.len:
    for id, target in result.targets:
      if id not_in c.declaredTargets:
        c.errors &= &"Undeclared target {Quoted id}."

  if c.errors.len != 0:
    raise (ref KdlDeserializationError)(msg: "Config validation failed", errors: move c.errors)

func getSettingsForApi*(target: Target; api: string): KdlDoc =
  result = target.settings
  if (let override = target.overrides.getOrDefault api; override != nil):
    result &= override[]
