from   std/math import isNaN
from   std/parseutils as pu import nil
from   std/paths import Path
from   std/sequtils import allIt, anyIt, countIt, mapIt
from   std/strbasics import nil
import std/strformat
from   std/strutils import `%`, addSep, join, replace, toLowerAscii
import std/tables
import questionable
import sourcegens/codegens
import sourcegens/emission
import sourcegens/identStyles
from   sourcegens/overridableTables import toOverridableTable
from   sourcegens/utils import dd
import ../backends
import ../discovery
import ../discovery/naming
from   ../discovery/renaming import assignNames, traverse
from   ../private/kdlDecoding import KdlDeserializationError, KdlDoc, deserializeKdlDoc
from   ../private/plurals import singularize

type
  Settings = object
    pathPattern, package, indentation: string
    names: NameAssignment

template getKdlFieldNames(_: type Settings; field: string): seq[string] =
  case field
  of "pathPattern": @["path"]
  of "names": @[]
  else: @[field]

type
  DNamingPolicy* = object of NamingPolicy

  UdaName = enum
    udaBase64Encoded
    udaByName
    udaDate
    udaDateTime
    udaDuration
    udaEmbedNullable
    udaFieldMask
    udaMaximum
    udaMinimum
    udaName
    udaOptional
    udaPattern
    udaReadOnly

  StructBodyContext = object
    attrs: seq[string]
    forbidden: set[UdaName]
    implicitOptional: bool

  Quoted = distinct string

using
  policy: var DNamingPolicy
  c: TargetConfig
  settings: ref Settings
  e: var Emitter
  api: AnalyzedApi
  names: NameAssignment

const
  camelCase = initIdentStyle(wordInitial = lcUpper)
  pascalCase = initIdentStyle(initial = lcUpper, wordInitial = lcUpper)
  snakeCase = initIdentStyle(wordSep = "_")
  kebabCase = initIdentStyle(wordSep = "-")
  typesModule = "d_types"
  methodsModule = "d_methods"
  autogeneratedComment = "// Autogenerated by discovery-gen v0.x.\p"

proc formatValue(s: var string; val: Quoted; _: string) =
  if val.string.allIt it in {' ' .. '_', 'a' .. '~'}:
    s.add '`'
    s.add val.string
    s.add '`'
  else:
    s.addQuoted val.string

method renameEnum*(policy; name: string): string =
  name.convertStyle pascalCase

method renameStruct*(policy; name: string): string =
  name.convertStyle pascalCase

method renameEnumMember*(policy; name: string): string =
  name.convertStyle camelCase

method renameStructMember*(policy; name: string): string =
  name.convertStyle camelCase

method renameResource*(policy; name: string): string =
  name.convertStyle snakeCase

func fixIdent(name: string): string =
  case name
  of  # https://dlang.org/spec/lex.html#keywords
      "abstract", "alias", "align", "asm", "assert", "auto", #["body",]# "bool", "break", "byte",
      "case", "cast", "catch", "cdouble", "cent", "cfloat", "char", "class", "const", "continue",
      "creal", "dchar", "debug", "default", "delegate", "delete", "deprecated", "do", "double",
      "else", "enum", "export", "extern", "false", "final", "finally", "float", "for", "foreach",
      "foreach_reverse", "function", "goto", "idouble", "if", "ifloat", "immutable", "import", "in",
      "inout", "int", "interface", "invariant", "ireal", "is", "lazy", "long", "macro", "mixin",
      "module", "new", "nothrow", "null", "out", "override", "package", "pragma", "private",
      "protected", "public", "pure", "real", "ref", "return", "scope", "shared", "short", "static",
      "struct", "super", "switch", "synchronized", "template", "this", "throw", "true", "try",
      "typeid", "typeof", "ubyte", "ucent", "uint", "ulong", "union", "unittest", "ushort",
      "version", "void", "wchar", "while", "with",
      # https://dlang.org/spec/property.html
      # https://dlang.org/spec/enum.html#enum_properties
      # https://dlang.org/spec/struct.html#struct_properties
      "alignof", "init", "mangleof", "max", "min", "offsetof", "sizeof", "stringof", "tupleof",
      "":
    name & '_'
  elif name[0] not_in '0' .. '9':
    name
  else:
    '_' & name

method fixIdent*(policy; name: string): string =
  name.fixIdent

func isHiddenType(header: TypeDeclHeader; info: TypeDeclHeaderNameInfo): bool =
  header.hasInferredName and (not header.hasCertainName or info.ambiguous or info.name.len <= 5)

func needsNullable(ty: Type): bool =
  ty.scalar.flags * {stfHasDefault, stfRequired} == { } and ty.containers.len == 0

template formatEitherInteger(kind: ScalarTypeKind; i32: int32; u32: uint32): string =
  if kind == stkI32:
    $i32
  else:
    var s = $u32
    s &= 'u'
    s

func formatMin(scalar: ScalarType): string =
  formatEitherInteger(scalar.kind, scalar.minI32, scalar.minU32)

func formatMax(scalar: ScalarType): string =
  formatEitherInteger(scalar.kind, scalar.maxI32, scalar.maxU32)

func toDocComment(s: string; trailingLineBreak = false): string =
  var idx = 0
  var line = ""
  while (idx += pu.skipWhitespace(s, idx); idx != s.len):
    idx += pu.parseUntil(s, line, {'\n', '\r'}, idx)
    strbasics.strip line, leading = false
    result.add if result.len != 0: "\p///\p/// " else: "/// "
    result.add line

  if result.len == 0:
    result = "///"
  if trailingLineBreak:
    result.add "\p"

proc emitDocComment(e; doc: string) =
  e.emit doc.toDocComment(trailingLineBreak = true)

proc emitAltDocs(e; docs: openArray[string]) =
  if docs.len != 0:
    e.emit docs[0].toDocComment(trailingLineBreak = true)
    for desc in docs.toOpenArray(1, docs.high):
      e.emit &dd"""
      /// ___
      {desc.toDocComment}
      """
  else:
    e.emit "///\p"

proc emitEnumMember(
  e; hasInvalidMembers: bool; id: int; member: EnumMember; info: TypeDeclNameInfo; deprecated: bool;
) =
  let name = info.memberNames[id]
  let haveAlias = not hasInvalidMembers and name != member.bare.name
  if haveAlias:
    if deprecated:
      e.emit "deprecated "
    e.emit &"{member.bare.name},\p" # Undocumented, but will be serialized as this name.

  e.emitAltDocs member.descriptions
  if deprecated:
    e.emit "deprecated "
  if hasInvalidMembers:
    e.emit &"@(.name({Quoted member.bare.name})) "
  e.emit name
  if haveAlias:
    e.emit &" = {id}"
  e.emit ",\p"

proc emitEnumDecl(e; en: EnumDecl; info: TypeDeclNameInfo) =
  let hasInvalidMembers = en.members.anyIt it.bare.name.fixIdent != it.bare.name
  let baseTy = if en.members.len <= 256: "ubyte" else: "ushort"
  e.emit &"///\penum {info.header.name}: {baseTy} {{\p"
  e.indent
  for i, member in en.members:
    e.emitEnumMember hasInvalidMembers, i, member, info, en.isDeprecated i.EnumMemberId
  e.dedent
  e.emit "}\p"

func initStructBodyContext(body: StructBody; memberNames: openArray[string]): StructBodyContext =
  result.implicitOptional = (
    stfRequired not_in body.anyMemberFlags and
    body.members.countIt(not it.bare.ty.needsNullable) > 1
  )
  result.attrs = newSeqOfCap[string] 5
  for name in memberNames:
    result.forbidden.incl:
      case name
      of "base64Encoded": udaBase64Encoded
      of "byName":        udaByName
      of "date":          udaDate
      of "dateTime":      udaDateTime
      of "duration":      udaDuration
      of "embedNullable": udaEmbedNullable
      of "fieldMask":     udaFieldMask
      of "maximum":       udaMaximum
      of "minimum":       udaMinimum
      of "name":          udaName
      of "optional":      udaOptional
      of "pattern":       udaPattern
      of "readOnly":      udaReadOnly
      else: continue

iterator memberUdas(m: BareStructMember; memberName: string; implicitOptional: bool):
    (UdaName, string) =
  let scalar = m.ty.scalar
  if stfRequired not_in scalar.flags:
    block blk:
      yield
        if m.ty.needsNullable: (udaEmbedNullable, "embedNullable")
        elif implicitOptional: break blk
        else:                  (udaOptional, "optional")
  if memberName != m.name and memberName != m.name & '_':
    yield (udaName, &"name({Quoted m.name})")
  if stfReadOnly in scalar.flags:
    yield (udaReadOnly, "readOnly")
  if stfHasMin in scalar.flags:
    yield (udaMinimum, &"minimum({scalar.formatMin})")
  if stfHasMax in scalar.flags:
    yield (udaMaximum, &"maximum({scalar.formatMax})")
  if stfHasPattern in scalar.flags:
    yield (udaPattern, &"pattern({Quoted scalar.pattern})")
  block blk:
    yield case scalar.kind:
      of stkBase64: (udaBase64Encoded, "base64Encoded")
      of stkDate: (udaDate, "date") # TODO: Use a custom type rather than a UDA.
      of stkDateTime: (udaDateTime, "dateTime") # TODO: Use a custom type rather than a UDA.
      of stkDuration: (udaDuration, "duration") # TODO: Use a custom type rather than a UDA.
      of stkFieldMask: (udaFieldMask, "fieldMask")
      of stkEnum: (udaByName, "byName")
      else: break blk

proc emitMemberUdas(
  e; c: var StructBodyContext; memberId: int; m: BareStructMember; memberNames: openArray[string];
) =
  let scalar = m.ty.scalar
  var simpleSyntax = true
  for (uda, code) in m.memberUdas(memberNames[memberId], c.implicitOptional):
    c.attrs.add:
      if uda not_in c.forbidden:
        code
      else:
        simpleSyntax = false
        '.' & code

  if c.attrs.len != 0:
    e.emit:
      if simpleSyntax:
        var s = newStringOfCap c.attrs.len shl 4
        for a in c.attrs:
          s &= '@'
          s &= a
          s &= ' '
        s
      else:
        let s = c.attrs.join ", "
        &"@({s}) "
    c.attrs.setLen 0

type MemberTypeAlias = object
  name: string
  tyInfo: ptr TypeDeclHeaderNameInfo
  hidden: bool

func getMemberTypeName(memberName: string; ty: Type): string =
  (if ty.containers.len == 0: memberName else: memberName.singularize).convertStyle(pascalCase)

proc emitMemberType(e; api: AnalyzedApi; names; memberName: string; ty: Type):
    MemberTypeAlias =
  if ty.needsNullable:
    e.emit "Nullable!"
  e.emit:
    case ty.scalar.kind
    of stkJson: "Json"
    of stkBool: "bool"
    of stkF32: "float"
    of stkF64: "double"
    of stkI32: "int"
    of stkU32: "uint"
    of stkI64: "long"
    of stkU64: "ulong"
    of stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask: "string"
    of stkEnum:
      result.tyInfo = addr names.getEnumInfo(ty.scalar.enumId).header
      result.hidden = api.getEnum(ty.scalar.enumId).header.isHiddenType result.tyInfo[]
      result.name = getMemberTypeName(memberName, ty)
      result.name
    of stkStruct:
      let header = addr api.getStruct(ty.scalar.structId).header
      let info = addr names.getStructInfo(ty.scalar.structId).header
      if header.hasInferredName:
        result.tyInfo = info
        result.hidden = header[].isHiddenType info[]
        result.name = getMemberTypeName(memberName, ty)
        result.name # No need to check `circular`.
      elif not ty.scalar.circular:
        info.name
      else:
        info.name & '*'
  for i in countDown(ty.containers.high, 0):
    e.emit:
      case ty.containers[i]
      of ckArray: "[ ]"
      of ckDict: "[string]"

proc emitDefaultVal(e; names; scalar: ScalarType; alias: MemberTypeAlias) =
  case scalar.kind
  of stkBool:
    if scalar.defaultBool:
      e.emit " = true"
  of stkF32:
    if not scalar.defaultF32.isNaN:
      e.emit &" = {scalar.defaultF32}"
  of stkF64:
    if not scalar.defaultF64.isNaN:
      e.emit &" = {scalar.defaultF64}"
  of stkI32:
    if scalar.defaultI32 != 0:
      e.emit &" = {scalar.defaultI32}"
  of stkU32:
    if scalar.defaultU32 != 0:
      e.emit &" = {scalar.defaultU32}"
  of stkI64:
    if scalar.defaultI64 != 0:
      e.emit &" = {scalar.defaultI64}"
  of stkU64:
    if scalar.defaultU64 != 0:
      e.emit &" = {scalar.defaultU64}"
  of stkString, stkBase64, stkDate, stkDateTime, stkDuration, stkFieldMask:
    if scalar.defaultString.len != 0:
      e.emit &" = {Quoted scalar.defaultString}"
  of stkEnum:
    if scalar.defaultMember.int != 0:
      let memberName = names.getEnumInfo(scalar.enumId).memberNames[scalar.defaultMember.int]
      assert alias.tyInfo != nil
      e.emit &" = {alias.name}.{memberName}"
  of stkJson, stkStruct: discard

proc emitMemberTypeAlias(e; alias: MemberTypeAlias) =
  let namespace = if alias.hidden: "_P" else: ""
  e.emit &"alias {alias.name} = {namespace}.{alias.tyInfo.name}; /// ditto\p"

proc emitStructBody(e; api; names; body: StructBody; memberNames: openArray[string]) =
  var ctx = initStructBodyContext(body, memberNames)
  if ctx.implicitOptional:
    e.emit if udaOptional in ctx.forbidden: "@(.optional):\p" else: "@optional:\p"

  e.indent
  for memberId, m in body.members:
    let memberName = memberNames[memberId]
    e.emitAltDocs m.descriptions
    e.emitMemberUdas ctx, memberId, m.bare, memberNames
    let alias = e.emitMemberType(api, names, memberName, m.bare.ty)
    e.emit &" {memberName}"
    if stfHasDefault in m.bare.ty.scalar.flags and m.bare.ty.containers.len == 0:
      e.emitDefaultVal names, m.bare.ty.scalar, alias
    e.emit ";\p"
    if alias.tyInfo != nil:
      e.emitMemberTypeAlias alias

  e.dedent

proc emitStructDecl(e; api; names; st: StructDecl; info: TypeDeclNameInfo) =
  e.emitDocComment st.description
  e.emit &"struct {info.header.name} {{\p"
  e.emitStructBody api, names, st.body, info.memberNames
  e.emit "}\p"

proc emitEnumDecls(e; api; names; hidden: bool) =
  for i, info in names.enumNameInfos:
    if api.enumDecls[i].header.isHiddenType(info.header) == hidden:
      e.emitEnumDecl api.enumDecls[i], info
      e.endSection

proc emitStructDecls(e; api; names; hidden: bool) =
  for i, info in names.structNameInfos:
    if api.structDecls[i].header.isHiddenType(info.header) == hidden:
      e.emitStructDecl api, names, api.structDecls[i], info
      e.endSection

func initTypesCodegen(c; settings): Codegen =
  declareCodegen('#', e):
    "autogenerated":
      e.emit autogeneratedComment

    "header":
      discard

    "module":
      e.emit &("module {settings.package}.{settings.names.rootResource}." & typesModule & ";\p")
      e.endSection

    "publicImports":
      e.emit "public import std.typecons: Nullable, apply, nullable; ///\p"
      if c.api.usesJsonType:
        e.emit "public import vibe.data.json: JSONException, Json; ///\p"
      e.endSection

    "imports":
      e.emit &dd"""
      import {settings.package}.d.attributes;
      import {settings.package}.d.http: GoogleHttpClient;
      """
      e.endSection

    "hiddenNamespaceHeader":
      e.emit "///\ppackage struct _P {\p"
      e.indent

    "hiddenEnums":
      e.emitEnumDecls c.api, settings.names, hidden = true

    "hiddenStructs":
      e.emitStructDecls c.api, settings.names, hidden = true

    "hiddenNamespaceFooter":
      e.dedent
      e.emit "}\p"
      e.endSection

    "enums":
      e.emitEnumDecls c.api, settings.names, hidden = false

    "structs":
      e.emitStructDecls c.api, settings.names, hidden = false

    "commonParameters":
      e.emit "///\pstruct CommonParameters {\p"
      e.emitStructBody c.api, settings.names, c.api.params, settings.names.paramNames
      e.emit "}\p"
      e.endSection

    "googleClient":
      e.emit dd"""
      ///
      struct GoogleClient {
        GoogleHttpClient client; ///
        CommonParameters params; ///
      }
      """
      e.endSection

func translateHttpMethod(m: string): string =
  if m == "DELETE": "delete_" else: m.toLowerAscii

proc emitMethodDecl(e; api; names; m: Method) =
  var restPath = ""
  for fragment in m.pathFragments:
    restPath.addSep ", "
    restPath.formatValue Quoted fragment, ""

  e.emitDocComment m.description
  e.emit &dd"""
  struct {m.name.convertStyle pascalCase} {{
    enum restHttpMethod = HttpMethod.{m.httpMethod.translateHttpMethod}; ///
    enum restPath = [{restPath}]; ///
  """
  if m.request.int >= 0:
    e.emit &"  alias Request = t.{names.getStructInfo(m.request).header.name}; ///\p"
  e.emit &"  alias Response = t.{names.getStructInfo(m.response).header.name}; ///\p"
  e.endSection

  e.emitStructBody api, names, m.params, m.params.members.mapIt it.bare.name.convertStyle camelCase
  e.emit "}\p"

func initMethodsCodegen(c; settings; packagePrefix: string; res: Resource): Codegen =
  declareCodegen('#', e):
    "autogenerated":
      e.emit autogeneratedComment

    "header":
      discard

    "module":
      e.emit fmt do:
        "module {settings.package}.{settings.names.rootResource}.{packagePrefix}" & methodsModule &
        ";\p"
      e.endSection

    "publicImports":
      e.emit "public import std.typecons: Nullable, apply, nullable; ///\p"
      e.endSection

    "imports":
      e.emit &dd"""
      import google_api.d.attributes;
      import google_api.d.http: HttpMethod;
      import t = {settings.package}.{settings.names.rootResource}.d_types;
      """
      e.endSection

    "methods":
      for m in res.methods:
        e.emitMethodDecl c.api, settings.names, m
        e.endSection

#[
func initPackageCodegen(c: Context): Codegen =
  declareCodegen('#', e):
    "autogenerated":
      e.emit autogeneratedComment

    "header":
      e.emit &dd"""
      /// {c.api.title}.
      ///
      {c.api.description.toDocComment}
      ///
      """
      if link =? c.api.documentationLink:
        e.emit &dd"""
        /// {link}
        ///
        """
      # https://dlang.org/spec/ddoc.html#standard_sections
      e.emit &dd"""
      /// Version: {c.api.version}
      /// Date: {c.api.revision}
      """

    "module":
      e.emit &"module {c.settings.package}.{c.api.name};\p"
      e.endSection
]#

func prepareFiles(c; settings): seq[(string, GenFileSpec)] =
  let path = block:
    var path = settings.pathPattern % c.rawApi.name.convertStyle kebabCase
    path &= '/'
    path &= settings.package.replace('.', '/')
    path &= '/'
    path &= settings.names.rootResource # Actually, `policy.renameDirectory c.rawApi.name`.
    path

  var
    fileSet = @[("types", GenFileSpec(
      path: path & '/' & typesModule & ".d",
      indent: settings.indentation,
      codegen: c.initTypesCodegen settings,
    ))]
    policy: DNamingPolicy

  # TODO: Emit top-level REST methods.
  {.cast(noSideEffect).}: # Policy methods are declared to be impure.
    c.api.resources.traverse(path.Path, policy) do (
      path: Path; packagePrefix: string; res: Resource;
    ) {.noSideEffect.}:
      let f = (packagePrefix & "methods", GenFileSpec(
        path: path.string & '/' & methodsModule & ".d",
        indent: settings.indentation,
        codegen: c.initMethodsCodegen(settings, packagePrefix, res),
      ))
      {.cast(noSideEffect).}:
        fileSet.add f

  fileSet

func deserializeSettings(doc: KdlDoc; settings: var Settings) =
  var errors: seq[string]
  doc.deserializeKdlDoc settings, errors, strict = false
  if settings.pathPattern.len == 0:
    errors &= "Missing `path`."

  if errors.len != 0:
    raise (ref KdlDeserializationError)(msg: "The D backend is misconfigured", errors: errors)

func initDTarget*(c; settings: sink KdlDoc): GenFilesetSpec =
  var policy: DNamingPolicy
  let dSettings = (ref Settings)(
    package: "google_api",
    indentation: "\t", # I cannot deny tabs are more compact.

    names: ({.cast(noSideEffect).}: c.api.assignNames policy),
  )
  {.cast(noSideEffect).}:
    settings.deserializeSettings dSettings[]
  c.prepareFiles(dSettings).toOverridableTable '#'
