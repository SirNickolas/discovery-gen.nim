from   std/algorithm import SortOrder, sort
from   std/enumerate import enumerate
from   std/parseutils as pu import nil
from   std/sequtils import mapIt
import std/strformat
from   std/strutils as su import nil
from   std/sugar import collect
import std/tables
import questionable
import ../discovery
from   ../private/plurals import singularize
import ../rawDiscovery

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
    aliases: Table[string, ptr DiscoveryJsonSchema]
    enumRegistry: Table[(seq[string], seq[bool]), EnumId]
    structRegistry: Table[string, StructId]
    anonRegistry: Table[seq[BareStructMember], StructId]
    scopeRegistry: Table[string, ScopeId]
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
  result = ScalarType(kind: stkBool)
  if def =? def:
    result.flags.incl stfHasDefault
    case def:
      of "true": result.defaultBool = true
      of "false": discard
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
    of "date": stkDate
    of "date-time", "google-datetime": stkDateTime
    of "google-duration": stkDuration
    of "google-fieldmask": stkFieldMask
    of "byte": stkBase64
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
        members[i].bare.name = name
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

func byTypeAndName(a, b: StructMember): int =
  cmp(a.bare, b.bare)

proc registerAnonStructType(c; body: sink StructBody): StructId =
  body.members.sort byTypeAndName
    # Total ordering in anonymous structs helps to deduplicate them more aggressively.
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
  let id = c.structRegistry[name]
  ScalarType(
    flags: {stfHasDefault},
    kind: stkStruct,
    structId: id,
    circular: checkSelfRef and id == c.curStructId,
      # A simple check for self-referential types. This does not handle mutually recursive types!
  )

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
      let alias = c.aliases.getOrDefault refName
      if alias == nil:
        result.scalar = c.analyzeRefType(refName, result.containers.len == 0)
        break

      member = alias # See comments in `analyze` below.
    else:
      case member.`type`
      of "any":
        if def =? member.default:
          raiseInvalidValue def, ty = "any"
        result.scalar = ScalarType(flags: {stfHasDefault}, kind: stkJson)
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
  c.api.usedTypes.incl ty.scalar.kind
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
      bare: BareStructMember(name: move c.curMemberName, ty: ty),
      descriptions: if description.len != 0: @[description] else: @[],
    )
  c.curMemberName = prevMemberName
#[
  End of mutually recursive group.
]#

proc reorderStructMembers(members: var openArray[StructMember]) =
  members.sort byTypeAndName
    # We order them by name because some JSON schemas are unstable: their fields shuffle every time
    # they are generated by Google. It seems to be the lesser evil to ignore existing ordering and
    # sort them ourselves.

proc analyzeStructBody(c; props: OrderedTable[string, DiscoveryJsonSchema]): StructBody =
  result = c.analyzeStructBodyAux props
  reorderStructMembers result.members

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

func splitMethodPath(path: string): seq[string] =
  var idx = 0
  var fragment = ""
  while (
    idx += pu.parseUntil(path, fragment, '{', idx) + 1;
    result &= fragment;
    idx < path.len
  ):
    idx += pu.skipUntil(path, '}', idx)
    idx += ord idx != path.len

func aggregateMemberFlags(members: openArray[StructMember]): tuple[all, any: set[ScalarTypeFlag]] =
  result.all = {ScalarTypeFlag.low .. ScalarTypeFlag.high}
  for m in members:
    result.all = result.all * m.bare.ty.scalar.flags
    result.any = result.any + m.bare.ty.scalar.flags

func analyzeMethodParameters(
  c; props: OrderedTable[string, DiscoveryJsonSchema]; order: openArray[string];
): (seq[StructMember], StructBody) =
  let posByName = collect initTable(order.len):
    for i, name in order:
      {name: i}
  var
    body = c.analyzeStructBodyAux props
    positional = newSeq[StructMember] order.len
    i = 0
    n = props.len
  while i != n:
    if (let pos = posByName.getOrDefault(body.members[i].bare.name, -1); pos >= 0):
      n -= 1
      positional[pos] = move body.members[i]
      body.members[i] = move body.members[n]
    else:
      i += 1

  assert n == props.len - order.len
  body.members.setLen n
  (body.allMemberFlags, body.anyMemberFlags) = aggregateMemberFlags body.members
  reorderStructMembers body.members
  (positional, body)

proc analyzeMethods(c; methods: OrderedTable[string, DiscoveryRestMethod]): seq[Method] =
  newSeq result, methods.len
  for i, (name, m) in enumerate methods.pairs:
    var (positionalParams, params) = c.analyzeMethodParameters(m.parameters, m.parameterOrder)
    result[i] = Method(
      name: name,
      httpMethod: m.httpMethod,
      description: m.description,
      pathFragments: splitMethodPath m.path,
      positionalParams: positionalParams,
      params: params,
      request: if request =? m.request: c.structRegistry[request.`$ref`] else: StructId(-1),
      response: c.structRegistry[m.response.`$ref`],
      deprecated: m.deprecated,
      scopes: m.scopes.mapIt c.scopeRegistry[it],
    )

proc analyzeResources(c; resources: Table[string, DiscoveryRestResource]): seq[Resource] =
  result = collect newSeqOfCap(resources.len):
    for name, res in resources:
      if res.deprecated:
        continue
      Resource(
        name: name,
        methods: c.analyzeMethods res.methods,
        children: c.analyzeResources res.resources,
      )

  result.sort do (a, b: Resource) -> int:
    cmp(a.name, b.name)

func isStructDecl(schema: DiscoveryJsonSchema): bool =
  schema.`type` == "object" and schema.additionalProperties.isNone

proc registerStructs(c; schemas: OrderedTable[string, DiscoveryJsonSchema]) =
  c.structRegistry = initTable[string, StructId] schemas.len
  c.api.structDecls = collect newSeqOfCap(schemas.len):
    for name, schema in schemas:
      if unlikely(not schema.isStructDecl):
        # A definition of a type alias. We will be expanding ("inlining") all aliases, discarding
        # their declared name and documentation in the process. Not perfect, yes.
        c.aliases[name] = ({.cast(noSideEffect).}: addr schemas.addr[][name])
          #[
            This is a hack. Whenever we encounter a reference to this name, we will continue
            traversing the JSON graph (not a tree anymore) from this position. Essentially a symlink
            in JSON. Note that symlinks open a possibility for infinite loops, and we have
            no defense against those. At the moment of writing, there existed only 4 aliases among
            the entire set of Google APIs so this hacky solution is hopefully acceptable.
          ]#
        continue

      c.structRegistry[name] = c.structRegistry.len.StructId
      StructDecl(
        header: TypeDeclHeader(names: @[name], hasCertainName: true),
        description: schema.description,
      )

proc registerScopes(c; scopes: OrderedTable[string, DiscoveryOAuth2Scope]) =
  newSeq c.api.scopeDecls, scopes.len
  c.scopeRegistry = collect initTable(scopes.len):
    for i, (name, scope) in enumerate scopes.pairs:
      c.api.scopeDecls[i] = ScopeDecl(name: name, description: scope.description)
      {name: i.ScopeId}

func analyze*(raw: DiscoveryRestDescription): AnalyzedApi =
  var c = Context(api: AnalyzedApi(name: raw.name), curStructId: StructId -1)
  # Build the registries before processing anything.
  c.registerStructs raw.schemas
  c.registerScopes raw.auth.oauth2.scopes

  c.api.params = c.analyzeStructBody raw.parameters
  var id = 0
  for schema in raw.schemas.values:
    if likely schema.isStructDecl:
      c.curStructId = id.StructId
      c.api.structDecls[id].body = c.analyzeStructBody schema.properties
      id += 1

  c.api.methods = c.analyzeMethods raw.methods
  c.api.resources = c.analyzeResources raw.resources

  for enumId, stats in c.enumStats:
    c.finalizeEnumDecl c.api.enumDecls[enumId], stats
  for anonId, stats in c.anonStats:
    c.finalizeAnonStructDecl c.api.structDecls[anonId + c.structRegistry.len], stats
  c.api
