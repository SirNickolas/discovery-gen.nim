from   std/paths import `/`, Path
from   std/strutils import replace
import sourcegens/codegens
import sourcegens/emission
from   sourcegens/overridableTables import toOverridableTable
import ../backends
from   ../discovery import DiscoveryRestDescription
from   ../private/kdlDecoding import deserializeKdlDoc

type Settings = object
  path: Path
  package: string

using
  api: DiscoveryRestDescription
  settings: Settings

const autogeneratedComment = "// Autogenerated by discovery-gen v0.x.\p"

func initCommonTypesCodegen(api; settings): Codegen =
  declareCodegen('#', e):
    "header":
      e.emit autogeneratedComment
      e.endSection

func prepareFiles(api; settings): seq[(string, GenFileSpec)] =
  let root = settings.path / settings.package.replace('.', '/').Path / api.name.Path
  const indent = "    "
  result.add ("commonTypes", GenFileSpec(
    path: string root / "declarations.d".Path,
    indent: indent,
    codegen: initCommonTypesCodegen(api, settings),
  ))

func initDTarget*(cfg: TargetConfig): GenFilesetSpec =
  prepareFiles(cfg.api, cfg.settings.deserializeKdlDoc(Settings, strict = false))
    .toOverridableTable '#'
