from kdl/types import KdlDoc
from sourcegens/codegens import GenFilesetSpec
from ./rawDiscovery import DiscoveryRestDescription
from ./discovery/analysis import AnalyzedApi, analyze

type
  TargetConfig* = ref object
    api: AnalyzedApi
    rawApi: DiscoveryRestDescription

  Backend* = proc (cfg: TargetConfig; settings: sink KdlDoc): GenFilesetSpec {.gcSafe.}

  BackendError* = object of CatchableError

func newTargetConfig*(rawApi: sink DiscoveryRestDescription): TargetConfig =
  TargetConfig(api: rawApi.analyze, rawApi: rawApi)

func api*(cfg: TargetConfig): lent AnalyzedApi = cfg.api
func rawApi*(cfg: TargetConfig): lent DiscoveryRestDescription = cfg.rawApi
