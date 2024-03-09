import std/tables
import ../discovery
import ../discovery/naming

export naming

type Context = object
  policy: ptr NamingPolicy
  registry: Table[string, ptr TypeDeclHeaderNameInfo]

using c: var Context

template renameMember(c: Context; member: BareEnumMember): string =
  c.policy[].renameEnumMember member.name

template renameMember(c: Context; member: BareStructMember): string =
  c.policy[].renameStructMember member.name

proc renameMember(c: Context; m: AggregateMember; requiredFixing: var bool): string =
  let naive = c.renameMember m.bare
  result = c.policy[].fixIdent naive
  if result != naive:
    requiredFixing = true

proc processEnumBody(c: Context; members: openArray[AggregateMember[BareEnumMember]]):
    TypeDeclBodyNameInfo[EnumMemberNameInfo] =
  newSeq result.members, members.len
  for i, m in members:
    result.members[i] = (name: c.renameMember(m, result.hadInvalidMembers))

proc processStructBody(c: Context; members: openArray[AggregateMember[BareStructMember]]):
    TypeDeclBodyNameInfo[StructMemberNameInfo] =
  newSeq result.members, members.len
  for i, m in members:
    result.members[i] = (name: c.renameMember(m, result.hadInvalidMembers), ty: "") # TODO.

proc assignDisambiguationId(c; header: var TypeDeclHeaderNameInfo) =
  let cell = addr c.registry.mgetOrPut(header.name, addr header)
  let prev = cell[]
  if prev == addr header:
    header.disambiguationId = -1
  else:
    if prev.disambiguationId < 0:
      prev.name = c.policy[].disambiguate(prev.name, 0)
      prev.disambiguationId = 0
    header.disambiguationId = prev.disambiguationId + 1
    header.name = c.policy[].disambiguate(header.name, header.disambiguationId)
    cell[] = addr header

proc processEnumDecl(c; info: var TypeDeclNameInfo[EnumMemberNameInfo]; en: EnumDecl) =
  info.header.name = c.policy[].fixIdent c.policy[].renameEnum en.header.names[0]
  info.body = c.processEnumBody en.members
  c.assignDisambiguationId info.header

proc processStructDecl(c; info: var TypeDeclNameInfo[StructMemberNameInfo]; st: StructDecl) =
  info.header.name = c.policy[].fixIdent c.policy[].renameStruct st.header.names[0]
  info.body = c.processStructBody st.body.members
  c.assignDisambiguationId info.header

proc assignNames*(api: AnalyzedApi; policy: var NamingPolicy): NameAssignment =
  var c = Context(policy: addr policy)
  result.apiName = policy.fixIdent policy.renameModule api.name
  result.paramsNameInfo = c.processStructBody api.params.members
  # These arrays must not reallocate since we take addresses of their members.
  newSeq result.enumNameInfos, api.enumDecls.len
  newSeq result.structNameInfos, api.structDecls.len
  for i, en in api.enumDecls:
    c.processEnumDecl result.enumNameInfos[i], en
  for i, st in api.structDecls:
    c.processStructDecl result.structNameInfos[i], st
