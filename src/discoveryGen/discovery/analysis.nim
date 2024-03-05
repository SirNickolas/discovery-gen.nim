from   std/algorithm import SortOrder, sort
from   std/enumerate import enumerate
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
  InvalidDefaultError* = object of DiscoveryAnalysisError
  InvalidBoundaryError* = object of DiscoveryAnalysisError
  UnknownFormatError* = object of DiscoveryAnalysisError
  MissingFieldError* = object of DiscoveryAnalysisError

  Quoted = distinct string

using c: var Context

template formatValue(s: string; val: Quoted; _: string) =
  s.addQuoted val.string

func raiseInvalidDefault(val, ty: string) {.noReturn, noInline.} =
  raise InvalidDefaultError.newException &"Invalid default value {Quoted val} for type \"{ty}\""

func raiseInvalidBoundary(val, ty: string) {.noReturn, noInline.} =
  raise InvalidBoundaryError.newException &"Invalid boundary {Quoted val} for type \"{ty}\""

func raiseUnknownFormat(format, ty: string) {.noReturn, noInline.} =
  raise UnknownFormatError.newException &"Unknown format {Quoted format} for type \"{ty}\""

func raiseMissingField(field, ty: string) {.noReturn, noInline.} =
  raise MissingFieldError.newException &"Missing \"{field}\" for type \"{ty}\""

proc analyzeAnonStructType(c; members: OrderedTable[string, DiscoveryJsonSchema]): StructTypeId
  {.raises: [DiscoveryAnalysisError, ValueError], tags: [], noSideEffect.}

func parseBooleanType(def: ?string): ScalarType =
  result = ScalarType(hasDefault: true, kind: stkBool)
  if def =? def:
    case def
    of "false": discard
    of "true": result.defaultBool = true
    else: raiseInvalidDefault def, ty = "boolean"

proc parseIntegerInto[T: int32 | uint32](s: string; dest: var T): bool =
  let x = su.parseBiggestInt s
  if x in T.low.int64 .. T.high.int64:
    dest = T x
    result = true

proc tee(x: bool; dest: var bool): bool =
  dest = x
  x

func parseIntegerType(format: string; def, minimum, maximum: ?string): ScalarType =
  case format
  of "int32":
    result = ScalarType(kind: stkI32)
    if def =? def and not def.parseIntegerInto(result.defaultI32).tee(result.hasDefault):
      raiseInvalidDefault def, ty = "integer/int32"
    if minimum =? minimum and not minimum.parseIntegerInto(result.minI32).tee(result.hasMin):
      raiseInvalidBoundary minimum, ty = "integer/int32"
    if maximum =? maximum and not maximum.parseIntegerInto(result.maxI32).tee(result.hasMax):
      raiseInvalidBoundary maximum, ty = "integer/int32"
  of "uint32":
    result = ScalarType(kind: stkU32)
    if def =? def and not def.parseIntegerInto(result.defaultU32).tee(result.hasDefault):
      raiseInvalidDefault def, ty = "integer/uint32"
    if minimum =? minimum and not minimum.parseIntegerInto(result.minU32).tee(result.hasMin):
      raiseInvalidBoundary minimum, ty = "integer/uint32"
    if maximum =? maximum and not maximum.parseIntegerInto(result.maxU32).tee(result.hasMax):
      raiseInvalidBoundary maximum, ty = "integer/uint32"
  else:
    raiseUnknownFormat format, ty = "integer"

func parseNumberType(format: string; def: ?string): ScalarType =
  case format
  of "float": ScalarType(
    hasDefault: true,
    kind: stkF32,
    defaultF32: if def =? def: float32 su.parseFloat def else: NaN.float32, # No validation.
  )
  of "double": ScalarType(
    hasDefault: true,
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
    result.hasDefault = true
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
        members[i] = (name: name, descriptions: newSeqOfCap[string] 1)
        {name: i.EnumMemberId}
    c.api.enumTypes &= EnumType(members: members, memberDeprecations: deprecated)
    c.enumStats &= EnumStats(descriptions: newSeq[CountTable[string]] names.len, memberIds: byName)

  c.enumStats[result.int].names.inc c.curMemberName
  for i, desc in descriptions:
    if desc.len != 0:
      c.enumStats[result.int].descriptions[i].inc desc

proc analyzeEnumType(c; schema: DiscoveryJsonSchema): ScalarType =
  let id = c.registerEnumType(schema.`enum`, schema.enumDescriptions, schema.enumDeprecated)
  result = ScalarType(hasDefault: true, kind: stkEnum, enumId: id)
  if def =? schema.default:
    result.defaultMember = c.enumStats[id.int].memberIds[def]

proc analyzeRefType(c; name: string; checkSelfRef: bool): ScalarType =
  if name not_in c.jsonAliases:
    result = ScalarType(hasDefault: true, kind: stkStruct, structId: c.structRegistry[name])
    # A simple check for self-referential types. This does not handle mutually recursive types!
    if checkSelfRef and result.structId == c.curStructId:
      result.circular = true
  else:
    result = ScalarType(hasDefault: true, kind: stkJson)
    c.api.usesJsonType = true

proc analyzeTypeAux(c; member: DiscoveryJsonSchema): Type =
  var member = addr member
  while true:
    if member.repeated:
      result.containers &= ckArray

    if refName =? member.`$ref`:
      if def =? member.default:
        raiseInvalidDefault def, ty = "$ref"
      result.scalar = c.analyzeRefType(refName, result.containers.len == 0)
      break

    case member.`type`:
      of "any":
        if def =? member.default:
          raiseInvalidDefault def, ty = "any"
        result.scalar = ScalarType(hasDefault: true, kind: stkJson)
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
          raiseInvalidDefault def, ty = "array"
        without itemSchema =? member.items:
          raiseMissingField "items", ty = "array"
        result.containers &= ckArray
        member = addr itemSchema[]
      of "object":
        if def =? member.default:
          raiseInvalidDefault def, ty = "object"
        without itemSchema =? member.additionalProperties:
          result.scalar = ScalarType(
            hasDefault: true,
            kind: stkStruct,
            structId: c.analyzeAnonStructType member.properties,
          )
          break
        result.containers &= ckDict
        member = addr itemSchema[]
      else:
        raise DiscoveryAnalysisError.newException &"Unknown type {Quoted member.`type`}"

  if pattern =? member.pattern:
    result.scalar.pattern = pattern
    result.scalar.hasPattern = true

proc analyzeMemberType(c; member: DiscoveryJsonSchema; info: var StructInfo):
    tuple[ty: Type; description: string] =
  var ty = c.analyzeTypeAux member
  if member.required:
    if ty.scalar.kind == stkStruct:
      raise DiscoveryAnalysisError.newException "Unsupported required parameter of type \"object\""
    ty.scalar.required = true
    info.hasRequiredMembers = true

  if member.deprecated:
    ty.scalar.deprecated = true
    info.hasDeprecatedMembers = true

  ty.scalar.readOnly = member.readOnly
  (ty, member.description)

proc analyzeAnonStructType(c; members: OrderedTable[string, DiscoveryJsonSchema]): StructTypeId =
  raiseAssert "Not implemented" # TODO.

proc analyzeStructBody(c; members: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  let prevMemberName = move c.curMemberName
  newSeq result.members, members.len
  for i, (name, member) in enumerate members.pairs:
    c.curMemberName = name
    let (ty, description) = c.analyzeMemberType(member, result.info)
    result.members[i] = ((name, ty), if description.len != 0: @[description] else: @[])

  result.members.sort do (a, b: StructMember) -> int:
    cmp(a.m.ty, b.m.ty)
  c.curMemberName = prevMemberName

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

func analyze*(raw: DiscoveryRestDescription): AnalyzedApi =
  var c = Context(curStructId: StructTypeId -1)
  newSeq c.api.structTypes, raw.schemas.len
  c.structRegistry = collect initTable(raw.schemas.len):
    for i, name in enumerate raw.schemas.keys:
      {name: i.StructTypeId}

  c.api.params = c.analyzeStructBody raw.parameters
  c.api.params.info.inferred = true
  c.finalizeEnumTypes
  c.api
