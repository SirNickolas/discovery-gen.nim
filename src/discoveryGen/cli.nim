import std/options
import std/sets
from   std/strutils import endsWith
import cligen
import ../discoveryGen

func combine[T](only, allBut: sink Option[HashSet[T]]; msg: string): HashSetPatch[T] =
  if only.isSome:
    if allBut.isSome:
      raise newException(HelpError, msg)
    result.mode = hspmOnly
    result.elems = move only.get
  elif allBut.isSome:
    result.elems = move allBut.get

proc genDiscoveryApisFromCli*(
  config: string;
  apiRoot = none string;
  targetRoot = none string;
  withApi = none HashSet[string];
  withoutApi = none HashSet[string];
  withTarget = none HashSet[string];
  withoutTarget = none HashSet[string];
): int =
  try:
    genDiscoveryApis(
      config, apiRoot, targetRoot,
      combine(withApi, withoutApi) do:
        "`--with-api` and `--without-api` are mutually exclusive.\n",
      combine(withTarget, withoutTarget) do:
        "`--with-target` and `--without-target` are mutually exclusive.\n",
    )
  except DiscoveryGenError as e:
    var msg = move e.msg
    if not msg.endsWith '\n':
      # if not msg.endsWith '.':
      #   msg &= '.'
      msg &= '\n'
    stderr.write msg
    return 1

proc argHelp*[T](defaultVal: Option[T]; ap: var ArgcvtParams): seq[string] =
  result = argHelp(defaultVal.get default T, ap)
  if defaultVal.isNone:
    result[2] = "(none)"

proc argParse*[T](dest: var Option[T]; defaultVal: Option[T]; ap: var ArgcvtParams): bool =
  let defaultVal = defaultVal.get default T
  var x = if dest.isSome: move dest.get else: defaultVal
  result = argParse(x, defaultVal, ap)
  if result:
    dest = some x

dispatchGen(
  genDiscoveryApisFromCli,
  dispatchName = "dispatchGenDiscoveryApisFromCli",
  cmdName = "discovery-gen",
  usage = "$command -c=<kdl> [optional-params]\n${doc}Options:\n$options",
  help = {
    "help":           "CLIGEN-NOHELP",
    "help-syntax":    "Show advanced help.",
    "version":        "Show program version.",
    "config":         "KDL config to use.",
    "api-root":       "Override config's `apiRoot`.",
    "target-root":    "Override config's `targetRoot`.",
    "with-api":       "Generate only specific APIs.",
    "without-api":    "Generate all but specific APIs.",
    "with-target":    "Generate only specific targets.",
    "without-target": "Generate all but specific targets.",
  },
  short = {
    "version": 'V',
    "api-root": '\0',
    "target-root": '\0',
    "with-api": 'a',
    "without-api": 'A',
    "with-target": 't',
    "without-target": 'T',
  },
)
export dispatchGenDiscoveryApisFromCli

const NimblePkgVersion {.strDefine.} = "0.0.0"
clCfg.version = NimblePkgVersion
clCfg.hTabCols = @[clOptKeys, clDescrip]
clCfg.sepChars = {'='}
clCfg.longPfxOk = false
clCfg.stopPfxOk = false
cgParseErrorExitCode = 2

when isMainModule:
  cligenQuit dispatchGenDiscoveryApisFromCli()
