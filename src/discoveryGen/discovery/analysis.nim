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
from   ../private/plurals import singularize
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
    curStructId: StructId
    curMemberName: string
    curMemberMultiple: bool
    jsonAliases: HashSet[string]
    enumRegistry: Table[(seq[string], seq[bool]), EnumId]
    structRegistry: Table[string, StructId]
    anonRegistry: Table[seq[BareStructMember], StructId]
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

func inferCurTypeName(c): string =
  if not c.curMemberMultiple:
    c.curMemberName
  else:
    c.curMemberName.singularize

proc registerEnumType(c; names, descriptions: seq[string]; deprecated: seq[bool]): EnumId =
  if names.len == 0:
    raise DiscoveryAnalysisError.newException "Enums with no members are not supported"
  if descriptions.len > names.len:
    raise DiscoveryAnalysisError.newException:
      &"Too many descriptions for enum {names}: {descriptions.len} > {names.len}"

  let nonExistent = c.enumStats.len.EnumId
  result = c.enumRegistry.mgetOrPut((names, deprecated), nonExistent)
  if result == nonExistent:
    var members = newSeq[EnumMember] names.len
    let byName = collect initTable(names.len):
      for i, name in names:
        members[i].bare = (name, )
        {name: i.EnumMemberId}
    c.api.enumDecls &= EnumDecl(
      header: TypeDeclHeader(hasInferredName: true),
      members: members,
      memberDeprecations: deprecated,
    )
    c.enumStats &= EnumStats(descriptions: newSeq[CountTable[string]] names.len, memberIds: byName)

  c.enumStats[result.int].names.inc c.inferCurTypeName
  for i, desc in descriptions: # May have fewer elements than we expect.
    if desc.len != 0:
      c.enumStats[result.int].descriptions[i].inc desc

proc analyzeEnumType(c; schema: DiscoveryJsonSchema): ScalarType =
  let id = c.registerEnumType(schema.`enum`, schema.enumDescriptions, schema.enumDeprecated)
  result = ScalarType(flags: {stfHasDefault}, kind: stkEnum, enumId: id)
  if def =? schema.default:
    result.defaultMember = c.enumStats[id.int].memberIds[def]

proc registerAnonStructType(c; body: sink StructBody): StructId =
  body.members.sort do (a, b: StructMember) -> int:
    # Total ordering in anonymous structs helps to deduplicate them more aggressively.
    cmp(a.bare, b.bare)

  let nonExistent = c.api.structDecls.len.StructId
  result = c.anonRegistry.mgetOrPut(body.members.mapIt it.bare, nonExistent)
  let anonId = result.int - c.structRegistry.len
  if result == nonExistent:
    var descriptions = newSeq[CountTable[string]] body.members.len
    for i, member in body.members.mpairs:
      descriptions[i] = toCountTable move member.descriptions
    c.anonStats &= AnonStats(descriptions: descriptions)
    c.api.structDecls &= StructDecl(header: TypeDeclHeader(hasInferredName: true), body: body)
  else:
    for i, t in c.anonStats[anonId].descriptions.mpairs:
      if body.members[i].descriptions.len != 0:
        t.inc body.members[i].descriptions[0]

  c.anonStats[anonId].names.inc c.inferCurTypeName

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
  let prevMultiple = c.curMemberMultiple
  var member = addr member
  while true:
    if member.repeated:
      result.containers &= ckArray
      c.curMemberMultiple = true

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
        c.curMemberMultiple = true
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
        c.curMemberMultiple = true
        member = addr itemSchema[]
      else:
        raise DiscoveryAnalysisError.newException &"Unknown type {Quoted member.`type`}"

  c.curMemberMultiple = prevMultiple
  if pattern =? member.pattern:
    result.scalar.pattern = pattern
    result.scalar.flags.incl stfHasPattern

proc analyzeMemberType(c; member: DiscoveryJsonSchema): tuple[ty: Type; description: string] =
  var ty = c.analyzeTypeAux member
  if member.required:
    if ty.scalar.kind == stkStruct:
      raise DiscoveryAnalysisError.newException "Unsupported required parameter of type \"object\""
    ty.scalar.flags.incl stfRequired
  if member.deprecated:
    ty.scalar.flags.incl stfDeprecated
  if member.readOnly:
    ty.scalar.flags.incl stfReadOnly
  (ty, member.description)

proc analyzeStructBodyAux(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  let prevMemberName = move c.curMemberName
  newSeq result.members, props.len
  result.allMemberFlags = {ScalarTypeFlag.low .. ScalarTypeFlag.high}
  for i, (name, member) in enumerate props.pairs:
    c.curMemberName = name
    let (ty, description) = c.analyzeMemberType member
    result.allMemberFlags = result.allMemberFlags * ty.scalar.flags
    result.anyMemberFlags = result.anyMemberFlags + ty.scalar.flags
    result.members[i] = StructMember(
      bare: (move c.curMemberName, ty),
      descriptions: if description.len != 0: @[description] else: @[],
    )
  c.curMemberName = prevMemberName
#[
  End of mutually recursive group.
]#

proc analyzeStructBody(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  result = c.analyzeStructBodyAux props
  result.members.sort do (a, b: StructMember) -> int:
    # In a named struct, we reorder members as little as necessary for a better layout.
    cmp(a.bare.ty, b.bare.ty)

proc sortKeysVia(t: CountTable[string]; tmp: var seq[(int, string)]): seq[string] =
  tmp.setLen 0
  tmp.setLen t.len
  for i, (k, v) in enumerate t.pairs:
    tmp[i] = (v, k)
  tmp.sort SortOrder.Descending

  newSeq result, t.len
  for i, (_, k) in tmp.mpairs:
    result[i] = move k

proc finalizeTypeDeclHeader(c; header: var TypeDeclHeader; names: CountTable[string]) =
  header.names = names.sortKeysVia c.tmp
  if c.tmp.len == 1 or c.tmp[0][0] != c.tmp[1][0]: # If we have a clear leader.
    header.hasCertainName = true

proc finalizeMemberDescriptions(
  c; members: var openArray[AggregateMember]; descriptionsTables: openArray[CountTable[string]];
) =
  for i, descriptions in descriptionsTables:
    members[i].descriptions = descriptions.sortKeysVia c.tmp

proc finalizeEnumDecl(c; en: var EnumDecl; stats: EnumStats) =
  c.finalizeTypeDeclHeader en.header, stats.names
  c.finalizeMemberDescriptions en.members, stats.descriptions

proc finalizeAnonStructDecl(c; st: var StructDecl; stats: AnonStats) =
  c.finalizeTypeDeclHeader st.header, stats.names
  c.finalizeMemberDescriptions st.body.members, stats.descriptions

func analyze*(raw: DiscoveryRestDescription): AnalyzedApi =
  var c = Context(api: AnalyzedApi(name: raw.name), curStructId: StructId -1)
  # Build the registry before processing anything.
  c.structRegistry = initTable[string, StructId] raw.schemas.len
  c.api.structDecls = collect newSeqOfCap(raw.schemas.len):
    for name, schema in raw.schemas:
      case schema.`type`
      of "object":
        # TODO: Support aliases to associative arrays (`schema.additionalProperties.isSome`).
        c.structRegistry[name] = c.structRegistry.len.StructId
      of "any":
        c.jsonAliases.incl name
        continue
      else:
        raise DiscoveryAnalysisError.newException:
          "Unsupported type \"" & schema.`type` & "\" for a global schema"

      StructDecl(
        header: TypeDeclHeader(names: @[name], hasCertainName: true),
        description: schema.description,
      )

  c.api.params = c.analyzeStructBody raw.parameters
  var id = 0
  for schema in raw.schemas.values:
    if schema.`type` == "object":
      c.curStructId = id.StructId
      c.api.structDecls[id].body = c.analyzeStructBody schema.properties
      id += 1

  for enumId, stats in c.enumStats:
    c.finalizeEnumDecl c.api.enumDecls[enumId], stats
  for anonId, stats in c.anonStats:
    c.finalizeAnonStructDecl c.api.structDecls[anonId + c.structRegistry.len], stats
  c.api
