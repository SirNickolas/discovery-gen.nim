from kdl/types import KdlDoc
from sourcegens/codegens import GenFilesetSpec
from ./discovery import DiscoveryRestDescription

type
  TargetConfig* = ref object
    api: DiscoveryRestDescription
    settings: KdlDoc

  Backend* = proc (cfg: TargetConfig): GenFilesetSpec {.gcSafe.}

func newTargetConfig*(api: sink DiscoveryRestDescription; settings: sink KdlDoc): TargetConfig =
  TargetConfig(api: api, settings: settings)

template api*(cfg: TargetConfig): DiscoveryRestDescription = cfg.api
template settings*(cfg: TargetConfig): KdlDoc = cfg.settings
