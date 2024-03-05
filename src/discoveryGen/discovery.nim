type
  # https://developers.google.com/discovery/v1/type-format
  ScalarTypeKind* = enum
    stkJson, stkBool, stkF32, stkF64, stkI32, stkU32, stkI64, stkU64,
    stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask,
    stkEnum, stkStruct

  StructTypeId* = distinct int
  EnumTypeId*   = distinct int
  EnumMemberId* = distinct int

  ScalarType* = object
    pattern*: string
    hasPattern*: bool
    hasDefault*: bool
    hasMin*, hasMax*: bool # Can only be present for `stkI32` and `stkU32`.
    required*: bool
    deprecated*: bool
    readOnly*: bool
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
      enumId*: EnumTypeId
      defaultMember*: EnumMemberId
    of stkStruct: # Always `hasDefault and not required`.
      structId*: StructTypeId
      circular*: bool

  ContainerKind* = enum
    ckArray, ckDict

  Type* = tuple
    containers: seq[ContainerKind]
    scalar: ScalarType

  Member* = tuple
    name: string
    ty: Type

  StructMember* = tuple
    m: Member
    descriptions: seq[string]

  StructInfo* = object
    inferred*, hasRequiredMembers*, hasDeprecatedMembers*: bool

  StructBody* = tuple
    members: seq[StructMember]
    info: StructInfo

  StructType* = object
    names*: seq[string]
    description*: string
    body*: StructBody

  EnumMember* = tuple
    name: string
    descriptions: seq[string]

  EnumType* = object
    names*: seq[string]
    members*: seq[EnumMember]
    memberDeprecations*: seq[bool] # Stored separately to save memory.

  AnalyzedApi* = object
    usesJsonType*: bool
    params*: StructBody
    enumTypes*: seq[EnumType]
    structTypes*: seq[StructType]
    # TODO: Methods.
    # TODO: Resources.

func `==`*(a, b: StructTypeId): bool {.borrow.}
func `==`*(a, b: EnumTypeId):   bool {.borrow.}
func `==`*(a, b: EnumMemberId): bool {.borrow.}

template getStruct*(api: AnalyzedApi; id: StructTypeId): StructType =
  api.structTypes[id.int]

template getEnum*(api: AnalyzedApi; id: EnumTypeId): EnumType =
  api.enumTypes[id.int]

template getMember*(e: EnumType; id: EnumMemberId): EnumMember =
  e.members[id.int]

func isDeprecated*(e: EnumType; id: EnumMemberId): bool =
  id.int < e.memberDeprecations.len and e.memberDeprecations[id.int]

func prio(ty: Type): int =
  if ty.containers.len == 0:
    case ty.scalar.kind
    of stkStruct:
      if not ty.scalar.circular: return 0 # An optimal place for structs of any size and alignment.
    of stkBool, stkEnum:
      return 1
    of stkF32, stkI32, stkU32:
      if ty.scalar.hasDefault: return 2
    else: discard
  3

func cmp*(a, b: Type): int =
  a.prio - b.prio

func cmp*(a, b: Member): int =
  result = a.ty.prio - b.ty.prio
  if result == 0:
    result = cmp(a.name, b.name)
