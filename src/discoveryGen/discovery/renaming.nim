from   std/sequtils import mapIt
import std/tables
import ../discovery
import ../discovery/naming

export naming

type Context = object
  policy: ptr NamingPolicy
  registry: Table[string, ptr TypeDeclHeaderNameInfo]

template members(st: StructDecl): openArray[StructMember] =
  st.body.members

template renameTypeDecl(c: Context; en: EnumDecl): string =
  c.policy[].renameEnum en.header.names[0]

template renameTypeDecl(c: Context; st: StructDecl): string =
  c.policy[].renameStruct st.header.names[0]

template renameMember(c: Context; member: BareEnumMember): string =
  c.policy[].renameEnumMember member.name

template renameMember(c: Context; member: BareStructMember): string =
  c.policy[].renameStructMember member.name

proc processTypeDeclBody(c: Context; members: openArray[AggregateMember]): seq[string] =
  members.mapIt c.policy[].fixIdent c.renameMember it.bare

proc assignDisambiguationId(c: var Context; header: var TypeDeclHeaderNameInfo) =
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

proc processTypeDecl(c: var Context; info: var TypeDeclNameInfo; decl: EnumDecl | StructDecl) =
  info.header.name = c.policy[].fixIdent c.renameTypeDecl decl
  info.memberNames = c.processTypeDeclBody decl.members
  c.assignDisambiguationId info.header

proc assignNames*(api: AnalyzedApi; policy: var NamingPolicy): NameAssignment =
  var c = Context(policy: addr policy)
  result.apiName = policy.fixIdent policy.renameModule api.name
  result.paramNames = c.processTypeDeclBody api.params.members
  # These arrays must not reallocate since we take addresses of their members.
  newSeq result.enumNameInfos, api.enumDecls.len
  newSeq result.structNameInfos, api.structDecls.len
  for i, en in api.enumDecls:
    c.processTypeDecl result.enumNameInfos[i], en
  for i, st in api.structDecls: # BUG: Should have priority.
    c.processTypeDecl result.structNameInfos[i], st
