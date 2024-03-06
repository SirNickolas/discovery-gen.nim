from   std/algorithm import SortOrder, sort
from   std/enumerate import enumerate
from   std/sequtils import mapIt
import std/sets
import std/strformat
from   std/strutils as su import nil
from   std/sugar import collect
import std/tables
import questionable
import ../discovery
from   ../rawDiscovery import DiscoveryJsonSchema, DiscoveryRestDescription

export discovery

type
  EnumStats = object
    names: CountTable[string]
    descriptions: seq[CountTable[string]]
    memberIds: Table[string, EnumMemberId]

  AnonStats = object
    names: CountTable[string]
    descriptions: seq[CountTable[string]]

  Context = object
    api: AnalyzedApi
    curStructId: StructTypeId
    curMemberName: string
    jsonAliases: HashSet[string]
    enumRegistry: Table[(seq[string], seq[bool]), EnumTypeId]
    structRegistry: Table[string, StructTypeId]
    anonRegistry: Table[seq[Member], StructTypeId]
    enumStats: seq[EnumStats]
    anonStats: seq[AnonStats]
    tmp: seq[(int, string)]

  DiscoveryAnalysisError* = object of CatchableError
  InvalidValueError* = object of DiscoveryAnalysisError
  UnknownFormatError* = object of DiscoveryAnalysisError
  MissingFieldError* = object of DiscoveryAnalysisError

  Quoted = distinct string

using c: var Context

template formatValue(s: string; val: Quoted; _: string) =
  s.addQuoted val.string

func raiseInvalidValue(val, ty: string) {.noReturn, noInline.} =
  raise InvalidValueError.newException &"Invalid value {Quoted val} for type \"{ty}\""

func raiseUnknownFormat(format, ty: string) {.noReturn, noInline.} =
  raise UnknownFormatError.newException &"Unknown format {Quoted format} for type \"{ty}\""

func raiseMissingField(field, ty: string) {.noReturn, noInline.} =
  raise MissingFieldError.newException &"Missing \"{field}\" for type \"{ty}\""

func parseBooleanType(def: ?string): ScalarType =
  result = ScalarType(flags: {stfHasDefault}, kind: stkBool)
  if def =? def:
    case def
    of "false": discard
    of "true": result.defaultBool = true
    else: raiseInvalidValue def, ty = "boolean"

proc parseIntegerField[T: int32 | uint32](
  destField: var T; val: ?string; destFlags: var set[ScalarTypeFlag]; flag: ScalarTypeFlag;
) =
  if val =? val:
    let x = su.parseBiggestInt val
    if x not_in T.low.int64 .. T.high.int64:
      raiseInvalidValue val, ty = "integer/" & $T
    destField = T x
    destFlags.incl flag

func parseIntegerType(format: string; def, minimum, maximum: ?string): ScalarType =
  case format
  of "int32":
    result = ScalarType(kind: stkI32)
    parseIntegerField result.defaultI32, def, result.flags, stfHasDefault
    parseIntegerField result.minI32, minimum, result.flags, stfHasMin
    parseIntegerField result.maxI32, maximum, result.flags, stfHasMax
  of "uint32":
    result = ScalarType(kind: stkU32)
    parseIntegerField result.defaultU32, def, result.flags, stfHasDefault
    parseIntegerField result.minU32, minimum, result.flags, stfHasMin
    parseIntegerField result.maxU32, maximum, result.flags, stfHasMax
  else:
    raiseUnknownFormat format, ty = "integer"

func parseNumberType(format: string; def: ?string): ScalarType =
  case format
  of "float": ScalarType(
    flags: {stfHasDefault},
    kind: stkF32,
    defaultF32: if def =? def: float32 su.parseFloat def else: NaN.float32, # No validation.
  )
  of "double": ScalarType(
    flags: {stfHasDefault},
    kind: stkF64,
    defaultF64: if def =? def: su.parseFloat def else: NaN,
  )
  else:
    raiseUnknownFormat format, ty = "number"

func parseStringFormat(format: ?string): ScalarTypeKind =
  if format =? format:
    case format
    of "int64": stkI64
    of "uint64": stkU64
    of "byte": stkBase64
    of "date": stkDate
    of "date-time", "google-datetime": stkDateTime
    of "google-duration": stkDuration
    of "google-fieldmask": stkFieldMask
    else: raiseUnknownFormat format, ty = "string"
  else:
    stkString

func parseStringType(kind: ScalarTypeKind; def: ?string): ScalarType =
  result = ScalarType(kind: kind)
  if def =? def:
    result.flags.incl stfHasDefault
    case kind:
      of stkI64: result.defaultI64 = su.parseBiggestInt def
      of stkU64: result.defaultU64 = su.parseBiggestUInt def
      else:      result.defaultString = def

proc registerEnumType(c; names, descriptions: seq[string]; deprecated: seq[bool]): EnumTypeId =
  if names.len == 0:
    raise DiscoveryAnalysisError.newException "Enums with no members are not supported"
  if descriptions.len > names.len:
    raise DiscoveryAnalysisError.newException:
      &"Too many descriptions for enum {names}: {descriptions.len} > {names.len}"

  let nonExistent = c.enumStats.len.EnumTypeId
  result = c.enumRegistry.mgetOrPut((names, deprecated), nonExistent)
  if result == nonExistent:
    var members = newSeq[EnumMember] names.len
    let byName = collect initTable(names.len):
      for i, name in names:
        members[i] = (name, @[])
        {name: i.EnumMemberId}
    c.api.enumTypes &= EnumType(members: members, memberDeprecations: deprecated)
    c.enumStats &= EnumStats(descriptions: newSeq[CountTable[string]] names.len, memberIds: byName)

  c.enumStats[result.int].names.inc c.curMemberName
  for i, desc in descriptions: # May have fewer elements than we expect.
    if desc.len != 0:
      c.enumStats[result.int].descriptions[i].inc desc

proc analyzeEnumType(c; schema: DiscoveryJsonSchema): ScalarType =
  let id = c.registerEnumType(schema.`enum`, schema.enumDescriptions, schema.enumDeprecated)
  result = ScalarType(flags: {stfHasDefault}, kind: stkEnum, enumId: id)
  if def =? schema.default:
    result.defaultMember = c.enumStats[id.int].memberIds[def]

proc registerAnonStructType(c; body: sink StructBody): StructTypeId =
  body.members.sort do (a, b: StructMember) -> int:
    cmp(a.m, b.m) # Total ordering in anonymous structs helps to deduplicate them more aggressively.

  let nonExistent = c.api.structTypes.len.StructTypeId
  result = c.anonRegistry.mgetOrPut(body.members.mapIt it.m, nonExistent)
  let anonId = result.int - c.structRegistry.len
  if result == nonExistent:
    var descriptions = newSeq[CountTable[string]] body.members.len
    for i, member in body.members.mpairs:
      descriptions[i] = toCountTable move member.descriptions
    body.info.inferred = true
    c.anonStats &= AnonStats(descriptions: descriptions)
    c.api.structTypes &= StructType(body: body)
  else:
    for i, t in c.anonStats[anonId].descriptions.mpairs:
      if body.members[i].descriptions.len != 0:
        t.inc body.members[i].descriptions[0]

  c.anonStats[anonId].names.inc c.curMemberName

proc analyzeRefType(c; name: string; checkSelfRef: bool): ScalarType =
  if name not_in c.jsonAliases:
    let id = c.structRegistry[name]
    ScalarType(
      flags: {stfHasDefault},
      kind: stkStruct,
      structId: id,
      circular: checkSelfRef and id == c.curStructId,
        # A simple check for self-referential types. This does not handle mutually recursive types!
    )
  else:
    c.api.usesJsonType = true
    ScalarType(flags: {stfHasDefault}, kind: stkJson)

#[
  Mutually recursive group.
]#
proc analyzeStructBodyAux(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody
  {.raises: [DiscoveryAnalysisError, ValueError], tags: [], noSideEffect.}

proc analyzeTypeAux(c; member: DiscoveryJsonSchema): Type =
  var member = addr member
  while true:
    if member.repeated:
      result.containers &= ckArray

    if refName =? member.`$ref`:
      if def =? member.default:
        raiseInvalidValue def, ty = "$ref"
      result.scalar = c.analyzeRefType(refName, result.containers.len == 0)
      break

    case member.`type`:
      of "any":
        if def =? member.default:
          raiseInvalidValue def, ty = "any"
        result.scalar = ScalarType(flags: {stfHasDefault}, kind: stkJson)
        c.api.usesJsonType = true
        break
      of "boolean":
        result.scalar = parseBooleanType member.default
        break
      of "integer":
        if format =? member.format:
          result.scalar = parseIntegerType(format, member.default, member.minimum, member.maximum)
          break
        raiseMissingField "format", ty = "integer"
      of "number":
        if format =? member.format:
          result.scalar = parseNumberType(format, member.default)
          break
        raiseMissingField "format", ty = "number"
      of "string":
        result.scalar =
          if member.`enum`.len == 0:
            parseStringType(member.format.parseStringFormat, member.default)
          else:
            c.analyzeEnumType member[]
        break
      of "array":
        if def =? member.default:
          raiseInvalidValue def, ty = "array"
        without itemSchema =? member.items:
          raiseMissingField "items", ty = "array"
        result.containers &= ckArray
        member = addr itemSchema[]
      of "object":
        if def =? member.default:
          raiseInvalidValue def, ty = "object"
        without itemSchema =? member.additionalProperties:
          result.scalar = ScalarType(
            flags: {stfHasDefault},
            kind: stkStruct,
            structId: c.registerAnonStructType c.analyzeStructBodyAux member.properties,
          )
          break
        result.containers &= ckDict
        member = addr itemSchema[]
      else:
        raise DiscoveryAnalysisError.newException &"Unknown type {Quoted member.`type`}"

  if pattern =? member.pattern:
    result.scalar.pattern = pattern
    result.scalar.flags.incl stfHasPattern

proc analyzeMemberType(c; member: DiscoveryJsonSchema; info: var StructInfo):
    tuple[ty: Type; description: string] =
  var ty = c.analyzeTypeAux member
  if member.required:
    if ty.scalar.kind == stkStruct:
      raise DiscoveryAnalysisError.newException "Unsupported required parameter of type \"object\""
    ty.scalar.flags.incl stfRequired
    info.hasRequiredMembers = true

  if member.deprecated:
    ty.scalar.flags.incl stfDeprecated
    info.hasDeprecatedMembers = true

  if member.readOnly:
    ty.scalar.flags.incl stfReadOnly
  (ty, member.description)

proc analyzeStructBodyAux(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  let prevMemberName = move c.curMemberName
  newSeq result.members, props.len
  for i, (name, member) in enumerate props.pairs:
    c.curMemberName = name
    let (ty, description) = c.analyzeMemberType(member, result.info)
    result.members[i] =
      ((move c.curMemberName, ty), if description.len != 0: @[description] else: @[])
  c.curMemberName = prevMemberName
#[
  End of mutually recursive group.
]#

proc analyzeStructBody(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  result = c.analyzeStructBodyAux props
  result.members.sort do (a, b: StructMember) -> int:
    # In a named struct, we reorder members as little as necessary for a better layout.
    cmp(a.m.ty, b.m.ty)

proc sortKeysVia(t: CountTable[string]; tmp: var seq[(int, string)]): seq[string] =
  tmp.setLen 0
  tmp.setLen t.len
  for i, (k, v) in enumerate t.pairs:
    tmp[i] = (v, k)
  tmp.sort SortOrder.Descending

  newSeq result, t.len
  for i, (_, k) in tmp.mpairs:
    result[i] = move k

proc finalizeEnumTypes(c) =
  for enumId, e in c.api.enumTypes.mpairs:
    e.names = c.enumStats[enumId].names.sortKeysVia c.tmp
    for i, descriptions in c.enumStats[enumId].descriptions:
      e.members[i].descriptions = descriptions.sortKeysVia c.tmp

proc finalizeAnonStructTypes(c) =
  for anonId, stats in c.anonStats:
    let structId = anonId + c.structRegistry.len
    c.api.structTypes[structId].names = stats.names.sortKeysVia c.tmp
    for i, member in c.api.structTypes[structId].body.members.mpairs:
      member.descriptions = stats.descriptions[i].sortKeysVia c.tmp

func analyze*(raw: DiscoveryRestDescription): AnalyzedApi =
  var c = Context(curStructId: StructTypeId -1)
  newSeq c.api.structTypes, raw.schemas.len
  c.structRegistry = collect initTable(raw.schemas.len):
    for i, name in enumerate raw.schemas.keys:
      # TODO: Handle aliases to JSON type.
      c.api.structTypes[i].names = @[name]
      {name: i.StructTypeId}

  c.api.params = c.analyzeStructBody raw.parameters
  c.api.params.info.inferred = true
  for i, schema in enumerate raw.schemas.values:
    c.curStructId = i.StructTypeId
    c.api.structTypes[i].description = schema.description
    c.api.structTypes[i].body = c.analyzeStructBody schema.properties

  c.finalizeEnumTypes
  c.finalizeAnonStructTypes
  c.api
