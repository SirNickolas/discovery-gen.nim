from ../discovery import EnumId, StructId

type NamingPolicy* = object of RootObj

using policy: var NamingPolicy

{.push base, gcSafe, tags: [].}

method renameEnum*(policy; name: string): string =
  name

method renameStruct*(policy; name: string): string =
  name

method renameEnumMember*(policy; name: string): string =
  name

method renameStructMember*(policy; name: string): string =
  name

method renameModule*(policy; name: string): string =
  name

method fixIdent*(policy; name: string): string =
  raiseAssert "Not implemented"

method disambiguate*(policy; name: string; id: int32): string =
  result = name & '_'
  result.addInt id

{.pop.} # base, gcSafe, tags: []

type
  TypeDeclBodyNameInfo* = object
    memberNames*: seq[string]
    hadInvalidMembers*: bool

  TypeDeclNameInfo* = object
    name*: string
    body*: TypeDeclBodyNameInfo
    disambiguationId*: int32 # TODO: Replace with a `bool`.

  NameAssignment* = object
    apiName*: string
    paramsNameInfo*: TypeDeclBodyNameInfo
    enumNameInfos*: seq[TypeDeclNameInfo]
    structNameInfos*: seq[TypeDeclNameInfo]

template getEnumInfo*(names: NameAssignment; id: EnumId): TypeDeclNameInfo =
  names.enumNameInfos[id.int]

template getStructInfo*(names: NameAssignment; id: StructId): TypeDeclNameInfo =
  names.structNameInfos[id.int]