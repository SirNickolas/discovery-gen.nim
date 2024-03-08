from std/math import isNaN

type
  # https://developers.google.com/discovery/v1/type-format
  ScalarTypeKind* = enum
    stkJson, stkBool, stkF32, stkF64, stkI32, stkU32, stkI64, stkU64,
    stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask,
    stkEnum, stkStruct

  ScalarTypeFlag* = enum
    stfHasPattern
    stfHasDefault
    stfHasMin # Can only be present for `stkI32` and `stkU32`.
    stfHasMax # Ditto.
    stfRequired
    stfDeprecated
    stfReadOnly

  StructId*     = distinct int
  EnumId*       = distinct int
  EnumMemberId* = distinct int

  ScalarType* = object
    pattern*: string
    flags*: set[ScalarTypeFlag]
    case kind*: ScalarTypeKind
    of stkJson: # Always `hasDefault`.
      discard
    of stkBool: # Always `hasDefault`.
      defaultBool*: bool
    of stkF32: # Always `hasDefault`.
      defaultF32*: float32
    of stkF64: # Always `hasDefault`.
      defaultF64*: float
    of stkI32:
      defaultI32*, minI32*, maxI32*: int32
    of stkU32:
      defaultU32*, minU32*, maxU32*: uint32
    of stkI64:
      defaultI64*: int64
    of stkU64:
      defaultU64*: uint64
    of stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask:
      defaultString*: string
    of stkEnum: # Always `hasDefault`.
      enumId*: EnumId
      defaultMember*: EnumMemberId
    of stkStruct: # Always `hasDefault and not required`.
      structId*: StructId
      circular*: bool

when sizeOf(ScalarType) != 3 * sizeOf(int) + max(2 * sizeOf(int), 12) and not defined nimdoc:
  {.warning: "ScalarType has incorrect size: " & $sizeOf(ScalarType).}

type
  ContainerKind* = enum
    ckArray, ckDict

  Type* = object
    containers*: seq[ContainerKind]
    scalar*: ScalarType

  BareStructMember* = tuple
    name: string
    ty: Type

  StructMember* = object
    bare*: BareStructMember
    descriptions*: seq[string]

  StructBody* = object
    members*: seq[StructMember]
    allMemberFlags*, anyMemberFlags*: set[ScalarTypeFlag]

  TypeDeclHeader* = object
    names*: seq[string]
    hasInferredName*, hasCertainName*: bool

  StructDecl* = object
    header*: TypeDeclHeader
    description*: string
    body*: StructBody

  EnumMember* = object
    name*: string
    descriptions*: seq[string]

  EnumDecl* = object
    header*: TypeDeclHeader
    members*: seq[EnumMember]
    memberDeprecations*: seq[bool] # Stored separately to save memory.

  AnalyzedApi* = object
    usesJsonType*: bool
    params*: StructBody
    enumDecls*: seq[EnumDecl]
    structDecls*: seq[StructDecl]
    # TODO: Methods.
    # TODO: Resources.

func `==`*(a, b: StructId):     bool {.borrow.}
func `==`*(a, b: EnumId):       bool {.borrow.}
func `==`*(a, b: EnumMemberId): bool {.borrow.}

func `==`*(a, b: ScalarType): bool =
  if (a.flags, a.kind, a.pattern) == (b.flags, b.kind, b.pattern):
    result = case a.kind:
      of stkJson:
        true
      of stkBool:
        a.defaultBool == b.defaultBool
      of stkF32:
        if a.defaultF32.isNaN: b.defaultF32.isNaN else: a.defaultF32 == b.defaultF32
      of stkF64:
        if a.defaultF64.isNaN: b.defaultF64.isNaN else: a.defaultF64 == b.defaultF64
      of stkI32:
        (a.defaultI32, a.minI32, a.maxI32) == (b.defaultI32, b.minI32, b.maxI32)
      of stkU32:
        (a.defaultU32, a.minU32, a.maxU32) == (b.defaultU32, b.minU32, b.maxU32)
      of stkI64:
        a.defaultI64 == b.defaultI64
      of stkU64:
        a.defaultU64 == b.defaultU64
      of stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask:
        a.defaultString == b.defaultString
      of stkEnum:
        (a.enumId, a.defaultMember) == (b.enumId, b.defaultMember)
      of stkStruct:
        (a.structId, a.circular) == (b.structId, b.circular)

func prio(ty: Type): int =
  if ty.containers.len == 0:
    case ty.scalar.kind
    of stkStruct:
      if not ty.scalar.circular: return 0 # An optimal place for structs of any size and alignment.
    of stkBool, stkEnum:
      return 1
    of stkF32, stkI32, stkU32:
      if stfHasDefault in ty.scalar.flags: return 2
    else: discard
  3

func cmp*(a, b: Type): int =
  a.prio - b.prio

func cmp*(a, b: BareStructMember): int =
  result = a.ty.prio - b.ty.prio
  if result == 0:
    result = cmp(a.name, b.name)

template getStruct*(api: AnalyzedApi; id: StructId): StructDecl =
  api.structDecls[id.int]

template getEnum*(api: AnalyzedApi; id: EnumId): EnumDecl =
  api.enumDecls[id.int]

template getMember*(e: EnumDecl; id: EnumMemberId): EnumMember =
  e.members[id.int]

func isDeprecated*(e: EnumDecl; id: EnumMemberId): bool =
  id.int < e.memberDeprecations.len and e.memberDeprecations[id.int]
