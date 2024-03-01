import std/strformat
from   kdl/nodes import isInt
import ./private/kdlDecoding

export KdlDeserializationError, KdlDoc

const
  configMajorVersion* = 1
  configMinorVersion* = 0

type
  RawConfigVersion = object
    major: int64
    minor: int64

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

template getKdlArgFields(T: type RawConfigVersion): seq[string] =
  @["major", "minor"]

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

# Imperative code:

func raiseInvalidHeader(msg: sink string) {.noReturn, noInline.} =
  raise (ref KdlDeserializationError)(msg: "Invalid KDL config header", errors: @[msg])

func recognizeVersionTag(node: KdlNode): bool =
  if (
    node.name != "configVersion" or
    node.args.len == 0 or
    not node.args[0].isInt or (block:
      if node.args[0].num != configMajorVersion:
        raiseInvalidHeader:
          &("Wrong major version: expected " & $configMajorVersion & ", found {node.args[0].num}.")
      node.args.len == 1 or not node.args[1].isInt or node.args[1].num < 0
    )
  ): raiseInvalidHeader(
    "The first directive must be `configVersion " &
    $configMajorVersion & ' ' & $configMinorVersion & "`."
  )

  node.args[1].num <= configMinorVersion

func loadRawConfig*(doc: openArray[KdlNode]): RawConfig =
  if doc.len == 0:
    raiseInvalidHeader "The config is empty."
  result.strict = recognizeVersionTag doc[0]
  if result.strict:
    discard doc[0].deserializeKdl(RawConfigVersion, strict = true)
  doc.toOpenArray(1, doc.high).deserializeKdlDoc(result, result.strict)
