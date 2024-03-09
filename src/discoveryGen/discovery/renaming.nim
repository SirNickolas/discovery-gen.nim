from   std/sequtils import mapIt
import std/tables
import ../discovery
import ../discovery/naming

export naming

type Context = object
  policy: ptr NamingPolicy
  registry: Table[string, tuple[weakHeader: ptr TypeDeclHeaderNameInfo; disambiguationId: int]]

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

proc assignDisambiguationId(c: var Context; header: var TypeDeclHeaderNameInfo; strong: bool) =
  let headerToPut = if strong: nil else: addr header
  let cell = addr c.registry.mgetOrPut(header.name, (weakHeader: headerToPut, disambiguationId: -1))
  if cell.weakHeader != headerToPut:
    assert not strong
    if cell.disambiguationId < 0 and cell.weakHeader != nil:
      # Previously declared symbol is weak and was supposed to be unambiguous.
      cell.weakHeader.name = c.policy[].disambiguate(header.name, 0)
      cell.weakHeader.ambiguous = true
      cell.disambiguationId = 1
    else:
      cell.disambiguationId += 1

    header.name = c.policy[].disambiguate(header.name, cell.disambiguationId)
    header.ambiguous = true

proc processTypeDecl(c: var Context; info: var TypeDeclNameInfo; decl: EnumDecl | StructDecl) =
  info.header.name = c.policy[].fixIdent c.renameTypeDecl decl
  info.memberNames = c.processTypeDeclBody decl.members
  c.assignDisambiguationId info.header, not decl.header.hasInferredName

proc assignNames*(api: AnalyzedApi; policy: var NamingPolicy): NameAssignment =
  var c = Context(policy: addr policy)
  result.apiName = policy.fixIdent policy.renameModule api.name
  result.paramNames = c.processTypeDeclBody api.params.members
  # These arrays must not reallocate since we take addresses of their members.
  newSeq result.structNameInfos, api.structDecls.len
  newSeq result.enumNameInfos, api.enumDecls.len
  for i, st in api.structDecls: # Should have priority over enums.
    c.processTypeDecl result.structNameInfos[i], st
  for i, en in api.enumDecls:
    c.processTypeDecl result.enumNameInfos[i], en
