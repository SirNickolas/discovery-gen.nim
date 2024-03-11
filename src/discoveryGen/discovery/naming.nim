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

method resourceSeparator*(policy): string =
  "."

method renameResource*(policy; name: string): string =
  name

method fixIdent*(policy; name: string): string =
  raiseAssert "Not implemented"

method renameDirectory*(policy; name: string): string =
  policy.fixIdent name

method disambiguate*(policy; name: string; id: Natural): string =
  result = newStringOfCap name.len + 5
  result.add name
  result.add '_'
  result.addInt id

{.pop.} # base, gcSafe, tags: []

type
  TypeDeclHeaderNameInfo* = object
    name*: string
    ambiguous*: bool

  TypeDeclNameInfo* = object
    header*: TypeDeclHeaderNameInfo
    memberNames*: seq[string]

  NameAssignment* = object
    rootResource*: string
    paramNames*: seq[string]
    enumNameInfos*: seq[TypeDeclNameInfo]
    structNameInfos*: seq[TypeDeclNameInfo]

template getEnumInfo*(names: NameAssignment; id: EnumId): TypeDeclNameInfo =
  names.enumNameInfos[id.int]

template getStructInfo*(names: NameAssignment; id: StructId): TypeDeclNameInfo =
  names.structNameInfos[id.int]
