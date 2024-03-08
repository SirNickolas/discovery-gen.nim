from   std/math import isNaN
from   std/paths import `/`, Path
from   std/sequtils import allIt
import std/strformat
from   std/strutils import `%`, join, replace
import std/tables
import questionable
import sourcegens/codegens
import sourcegens/emission
import sourcegens/identStyles
from   sourcegens/overridableTables import toOverridableTable
from   sourcegens/utils import dd
import ../backends
import ../discovery
from   ../private/kdlDecoding import KdlDeserializationError, KdlDoc, deserializeKdlDoc
from   ../private/plurals import singularize
from   ../rawDiscovery import DiscoveryJsonSchema, DiscoveryRestDescription

type Settings = object
  pathPattern, package, indentation: string

template getKdlFieldNames(_: type Settings; field: string): seq[string] = @[
  case field
  of "pathPattern": "path"
  else: field
]

type
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
    attrs, names: seq[string]
    forbidden: set[UdaName]

  Quoted = distinct string

using
  e: var Emitter
  api: AnalyzedApi
  c: TargetConfig
  settings: ref Settings

const
  camelCase = IdentStyle(wordInitial: lcUpper)
  pascalCase = IdentStyle(initial: lcUpper, wordInitial: lcUpper)
  typesModule = "d_types"
  autogeneratedComment = "// Autogenerated by discovery-gen v0.x.\p"

proc formatValue(s: var string; val: Quoted; _: string) =
  if val.string.allIt it in {' ' .. '_', 'a' .. '~'}:
    s.add '`'
    s.add val.string
    s.add '`'
  else:
    s.addQuoted val.string

func needsNullable(ty: Type): bool =
  stfHasDefault not_in ty.scalar.flags and ty.containers.len == 0

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

func toComment(s: string): string =
  # TODO: Perform a smarter replacement.
  s.replace("\n", "\p///\p/// ")

proc emitDocComment(e; doc: string) =
  if doc.len != 0:
    e.emit &"/// {doc.toComment}\p"
  else:
    e.emit "///\p"

proc emitAltDocs(e; docs: openArray[string]) =
  if docs.len != 0:
    e.emit &"/// {docs[0].toComment}\p"
    for desc in docs.toOpenArray(1, docs.high):
      e.emit &dd"""
      /// ___
      /// {desc.toComment}
      """
  else:
    e.emit "///\p"

proc emitEnumMember(e; member: EnumMember; deprecated: bool) =
  e.emitAltDocs member.descriptions
  if deprecated:
    e.emit "deprecated "
  e.emit &"{member.name},\p" # TODO: Convert to camel case.

proc emitEnumDecl(e; en: EnumDecl) =
  let baseTy = if en.members.len <= 256: "ubyte" else: "ushort"
  e.emit &"///\penum {en.names[0].convertStyle pascalCase}: {baseTy} {{\p"
  e.indent
  for i, member in en.members:
    e.emitEnumMember member, en.isDeprecated i.EnumMemberId
  e.dedent
  e.emit "}\p"

func initStructBodyContext(members: openArray[StructMember]): StructBodyContext =
  result.attrs = newSeqOfCap[string] 5
  newSeq result.names, members.len
  for i, (m, _) in members:
    result.names[i] = m.name.convertStyle camelCase
    result.forbidden.incl:
      case result.names[i]
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

iterator memberUdas(c: StructBodyContext; memberId: int; m: BareStructMember): (UdaName, string) =
  let scalar = m.ty.scalar
  if stfRequired not_in scalar.flags:
    yield if m.ty.needsNullable: (udaEmbedNullable, "embedNullable") else: (udaOptional, "optional")
  if c.names[memberId] != m.name:
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

proc emitMemberUdas(e; c: var StructBodyContext; memberId: int; m: BareStructMember) =
  let scalar = m.ty.scalar
  var simpleSyntax = true
  for (uda, code) in c.memberUdas(memberId, m):
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

proc emitMemberType(e; api; ty: Type; memberName: string) =
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
    of stkEnum: api.getEnum(ty.scalar.enumId).names[0].convertStyle(pascalCase)
    of stkStruct:
      let st = api.getStruct ty.scalar.structId
      if st.hasInferredName:
        memberName.convertStyle pascalCase
      else:
        var s = st.names[0].convertStyle pascalCase
        if ty.scalar.circular:
          s &= '*'
        s
  for i in countDown(ty.containers.high, 0):
    e.emit:
      case ty.containers[i]
      of ckArray: "[ ]"
      of ckDict: "[string]"

proc emitDefaultVal(e; api; scalar: ScalarType) =
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
      let
        en = api.getEnum scalar.enumId
        eName = en.names[0].convertStyle pascalCase
        eMemberName = en.getMember(scalar.defaultMember).name.convertStyle(camelCase)
      e.emit &" = {eName}.{eMemberName}"
  of stkJson, stkStruct: discard

proc emitStructBody(e; api; body: StructBody) =
  var ctx = initStructBodyContext body.members
  e.indent
  for memberId, (m, descriptions) in body.members:
    let memberName =
      if m.ty.containers.len == 0:
        ctx.names[memberId]
      else:
        ctx.names[memberId].singularize

    e.emitAltDocs descriptions
    e.emitMemberUdas ctx, memberId, m
    e.emitMemberType api, m.ty, memberName
    e.emit &" {ctx.names[memberId]}"
    if stfHasDefault in m.ty.scalar.flags and m.ty.containers.len == 0:
      e.emitDefaultVal api, m.ty.scalar
    e.emit ";\p"

    if m.ty.scalar.kind == stkStruct:
      let st = api.getStruct m.ty.scalar.structId
      if st.hasInferredName:
        let localName = memberName.convertStyle pascalCase
        let globalName = st.names[0].convertStyle pascalCase
        e.emit &"alias {localName} = .{globalName}; /// ditto\p"

  e.dedent

proc emitStructDecl(e; api; st: StructDecl) =
  e.emitDocComment st.description
  e.emit &"struct {st.names[0].convertStyle pascalCase} {{\p"
  e.emitStructBody api, st.body
  e.emit "}\p"

func initTypesCodegen(c; settings): Codegen =
  declareCodegen('#', e):
    "autogenerated":
      e.emit autogeneratedComment

    "header":
      discard

    "module":
      e.emit &("module {settings.package}.{c.rawApi.name}." & typesModule & ";\p")
      e.endSection

    "publicImports":
      e.emit "public import std.typecons: Nullable, nullable; ///\p"
      e.endSection

    "imports":
      if c.api.usesJsonType:
        e.emit "import vibe.data.json: Json;\p"
      e.emit &dd"""
      import {settings.package}.d.attributes;
      import {settings.package}.d.http: GoogleHttpClient;
      """
      e.endSection

    "enums":
      for en in c.api.enumDecls:
        e.emitEnumDecl en
        e.endSection

    "commonParameters":
      e.emit "///\pstruct CommonParameters {\p"
      e.emitStructBody c.api, c.api.params
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

    "structs":
      for st in c.api.structDecls:
        e.emitStructDecl c.api, st
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
      /// {c.api.description.toComment}
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
  let root =
    (settings.pathPattern % c.rawApi.name).Path /
    settings.package.replace('.', '/').Path /
    c.rawApi.name.Path
  result.add ("types", GenFileSpec(
    path: string root / Path typesModule & ".d",
    indent: settings.indentation,
    codegen: c.initTypesCodegen settings,
  ))

func deserializeSettings(doc: KdlDoc; settings: var Settings) =
  var errors: seq[string]
  doc.deserializeKdlDoc settings, errors, strict = false
  if settings.pathPattern.len == 0:
    errors &= "Missing `path`."

  if errors.len != 0:
    raise (ref KdlDeserializationError)(msg: "The D backend is misconfigured", errors: errors)

func initDTarget*(c: TargetConfig; settings: sink KdlDoc): GenFilesetSpec =
  let dSettings = (ref Settings)(
    package: "google_api",
    indentation: "\t", # I cannot deny tabs are more compact.
  )
  {.cast(noSideEffect).}:
    settings.deserializeSettings dSettings[]
  c.prepareFiles(dSettings).toOverridableTable '#'
