import std/tables
import ../discovery
import ../discovery/naming

export naming

type Context = object
  policy: ptr NamingPolicy
  registry: Table[string, ptr TypeDeclHeaderNameInfo]

using c: var Context

# TODO: Export them?
template info(T: type BareEnumMember):   type = EnumMemberNameInfo
template info(T: type BareStructMember): type = StructMemberNameInfo

proc createMemberInfo(c: Context; M: type EnumMemberNameInfo; name: string): M =
  (name, )

proc createMemberInfo(c: Context; M: type StructMemberNameInfo; name: string): M =
  (name: name, ty: "") # TODO.

proc processDeclBody[B](c: Context; members: openArray[AggregateMember[B]]):
    TypeDeclBodyNameInfo[B.info] =
  newSeq result.members, members.len
  for i, m in members:
    let naive = c.policy[].renameMember m.bare
    let fixed = c.policy[].fixIdent naive
    if fixed != naive:
      result.hadInvalidMembers = true
    result.members[i] = c.createMemberInfo(B.info, fixed)

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

proc processEnumDecl(c; info: var TypeDeclNameInfo; en: EnumDecl) =
  info.header.name = c.policy[].fixIdent c.policy[].renameEnum en.header.names[0]
  info.body = c.processDeclBody en.members
  c.assignDisambiguationId info.header

proc processStructDecl(c; info: var TypeDeclNameInfo; st: StructDecl) =
  info.header.name = c.policy[].fixIdent c.policy[].renameStruct st.header.names[0]
  info.body = c.processDeclBody st.body.members
  c.assignDisambiguationId info.header

proc assignNames*(api: AnalyzedApi; policy: var NamingPolicy): NameAssignment =
  var c = Context(policy: addr policy)
  result.apiName = policy.fixIdent policy.renameModule api.name
  result.paramsNameInfo = c.processDeclBody api.params.members
  # These arrays must not reallocate since we take addresses of their members.
  newSeq result.enumNameInfos, api.enumDecls.len
  newSeq result.structNameInfos, api.structDecls.len
  for i, en in api.enumDecls:
    c.processEnumDecl result.enumNameInfos[i], en
  for i, st in api.structDecls:
    c.processStructDecl result.structNameInfos[i], st
