import std/tables
import ../discovery
import ../discovery/naming

export naming

type Context = object
  policy: ptr NamingPolicy
  registry: Table[string, ptr TypeDeclNameInfo]

using c: var Context

proc processDeclBody[B](c: Context; members: openArray[AggregateMember[B]]): TypeDeclBodyNameInfo =
  newSeq result.memberNames, members.len
  for i, m in members:
    let naive =
      when B is BareStructMember:
        c.policy[].renameStructMember m.bare.name
      else:
        c.policy[].renameEnumMember m.bare
    let fixed = c.policy[].fixIdent naive
    if fixed != naive:
      result.hadInvalidMembers = true
    result.memberNames[i] = fixed

proc assignDisambiguationId(c; info: var TypeDeclNameInfo) =
  let cell = addr c.registry.mgetOrPut(info.name, addr info)
  let prev = cell[]
  if prev == addr info:
    info.disambiguationId = -1
  else:
    if prev.disambiguationId < 0:
      prev.name = c.policy[].disambiguate(prev.name, 0)
      prev.disambiguationId = 0
    info.disambiguationId = prev.disambiguationId + 1
    info.name = c.policy[].disambiguate(info.name, info.disambiguationId)
    cell[] = addr info

proc processEnumDecl(c; info: var TypeDeclNameInfo; en: EnumDecl) =
  info.name = c.policy[].fixIdent c.policy[].renameEnum en.header.names[0]
  info.body = c.processDeclBody en.members
  c.assignDisambiguationId info

proc processStructDecl(c; info: var TypeDeclNameInfo; st: StructDecl) =
  info.name = c.policy[].fixIdent c.policy[].renameStruct st.header.names[0]
  info.body = c.processDeclBody st.body.members
  c.assignDisambiguationId info

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
