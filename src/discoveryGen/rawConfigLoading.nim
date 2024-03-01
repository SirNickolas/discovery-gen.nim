import ./private/kdlDecoding

export KdlDeserializationError, KdlDoc

const
  configMajorVersion* = 1
  configMinorVersion* = 0

type
  # TODO: Use when some form of `{.kdlEmbedded.}` is implemented.
  # RawApiSettings* = object
  #   discovery*: string

  RawApiOverride* = object
    targets*: seq[string]
    discovery*: string

  RawApi* = object
    ids*: seq[string]
    discovery*: string
    overrides*: seq[RawApiOverride]

  RawTargetOverride* = object
    ids*: seq[string]
    settings*: KdlDoc

  RawTarget* = object
    id*: string
    lang*: string
    settings*: KdlDoc
    overrides*: seq[RawTargetOverride]

  RawConfig* = object
    strict*: bool
    apiRoot*, targetRoot*: string
    apis*: seq[RawApi]
    targets*: seq[RawTarget]

template getKdlArgFields*(T: type RawApiOverride): seq[string] =
  @["targets"]

template getKdlArgFields*(T: type RawApi): seq[string] =
  @["ids"]

func getKdlFieldNames*(T: type RawApi; field: string): seq[string] = @[
  case field
  of "overrides": "withTargets"
  else: field
]

template getKdlArgFields*(T: type RawTargetOverride): seq[string] =
  @["ids"]

template getKdlChildrenStorage*(dest: RawTargetOverride): untyped =
  dest.settings

template getKdlArgFields*(T: type RawTarget): seq[string] =
  @["id"]

template getKdlPropFields*(T: type RawTarget): seq[string] =
  @["lang"]

func getKdlFieldNames*(T: type RawTarget; field: string): seq[string] = @[
  case field
  of "overrides": "withApis"
  else: field
]

func getKdlFieldNames*(T: type RawConfig; field: string): seq[string] =
  case field
  of "strict": @[]
  of "apis": @["api"]
  of "targets": @["target"]
  else: @[field]

func loadRawConfig*(doc: openArray[KdlNode]): RawConfig =
  result.strict = doc.deserializeKdlDocWithVersion(
    result, "configVersion", configMajorVersion, configMinorVersion,
  )
