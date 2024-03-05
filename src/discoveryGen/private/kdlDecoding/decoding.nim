import std/options
from   std/paths import Path
import std/sets
import std/strformat
import std/tables
import kdl/nodes
import kdl/types
import ./macros

export
  types.KdlDoc, types.KdlError, types.KdlNode, types.KdlVal, types.KValKind,
  macros.getKdlArgFields, macros.getKdlFieldNames, macros.getKdlPropFields

type
  SeqOrSomeSet*[T] = seq[T] | SomeSet[T]
  SimpleKdlVal* = bool | int64 | float | string | Path | Option[SimpleKdlVal]
  Quoted = distinct string
  BareNode {.borrow: `.`.} = distinct KdlNode

using
  node: KdlNode
  errors: var seq[string]
  strict: bool

template `&=`[T](x: SomeSet[T]; y: T) =
  x.incl y

template formatValue(s: string; val: Quoted; _: string) =
  s.addQuoted val.string

proc formatValue(s: var string; val: BareNode; _: string) =
  if val.tag.isSome:
    s.add '('
    s.addQuoted val.tag.unsafeGet
    s.add ')'
  s.addQuoted val.name

proc checkArgsMaxLen(node; n: Natural; errors) =
  if node.args.len > n:
    errors &= &"Node {BareNode node} has extra arguments: expected {n}, found {node.args.len}."

proc checkNoProps(node; errors) =
  if node.props.len != 0:
    errors &= &"Node {BareNode node} should not have properties; found {node.props.len}."

proc checkNoChildren(node; errors) =
  if node.children.len != 0:
    errors &= &"Node {BareNode node} should not have children; found {node.children.len}."

proc checkNoTag(node; errors) =
  if node.tag.isSome:
    errors &= &"Tag is not allowed: ({Quoted node.tag.unsafeGet}){Quoted node.name}."

proc checkNoTag(node; val: KdlVal; errors) =
  if val.tag.isSome:
    errors &= &"Tag is not allowed in node {BareNode node}: {val}."

proc checkNoTagsInArgs(node; n: Natural; errors) =
  for i in 0 ..< n:
    node.checkNoTag node.args[i], errors

proc deserializeKdlVal*(val: KdlVal; dest: var bool): bool =
  result = val.isBool
  if result:
    dest = val.boolean

proc deserializeKdlVal*(val: KdlVal; dest: var int64): bool =
  result = val.isInt
  if result:
    dest = val.num

proc deserializeKdlVal*(val: KdlVal; dest: var float): bool =
  if val.isFloat:
    dest = val.fnum
    true
  elif val.isInt and val.num in -0x200000_00000000 .. 0x200000_00000000:
    dest = val.num.float
    true
  else:
    false

proc deserializeKdlVal*(val: KdlVal; dest: var string): bool =
  result = val.isString
  if result:
    dest = val.str

template deserializeKdlVal*(val: KdlVal; dest: Path): bool =
  val.deserializeKdlVal dest.string

#[
proc deserializeKdlVal*[T](val: KdlVal; dest: var ref T): bool =
  if not val.isNull:
    var x = if not dest.isNil: move dest[] else: default T
    result = val.deserializeKdlVal x
    if dest.isNil:
      if not result:
        return
      new dest
    dest[] = x
  else:
    result = true
    dest = nil
]#

proc deserializeKdlVal*[T](val: KdlVal; dest: var Option[T]): bool =
  if not val.isNull:
    var x = if dest.isSome: move dest.get else: default T
    result = val.deserializeKdlVal x
    if result or dest.isSome:
      dest = some x
  else:
    result = true
    dest = none T

proc deserializeKdlArgs*[T](args: openArray[KdlVal]; dest: var Option[T]): int =
  if args.len == 0:
    return 0
  when T is SimpleKdlVal:
    if args[0].deserializeKdlVal dest: 1 else: -1
  else:
    var x = if dest.isSome: move dest.get else: default T
    result = args.deserializeKdlArgs x
    if result >= 0 or dest.isSome:
      dest = some x

proc deserializeKdlArgs*[T: SimpleKdlVal](args: openArray[KdlVal]; dest: var SeqOrSomeSet[T]): int =
  for i, arg in args:
    var x: T
    if not arg.deserializeKdlVal x:
      return i
    dest &= x
  args.len

proc deserializeKdlArgs*[T](args: openArray[KdlVal]; dest: var T): int =
  when T is SimpleKdlVal:
    if args.len != 0 and args[0].deserializeKdlVal dest:
      1
    else:
      -1
  else:
    var tmp = dest
    let last = args.high
    withEachArgField tmp, field:
      let n = args.toOpenArray(result, last).deserializeKdlArgs field
      if n < 0:
        return n
      result += n
    dest = tmp

template getKdlArgsStorage*(dest: typed): untyped = dest
template getKdlPropsStorage*(dest: typed): untyped = dest
template getKdlChildrenStorage*(dest: typed): untyped = dest

func formatInvalidValMsg(node; ty: string; val: KdlVal): string =
  &"Invalid value for {BareNode node}: expected {ty}, found {val}."

func formatMissingValMsg(node; ty: string): string =
  &"Missing a value for {BareNode node}; expected {ty}."

proc deserializeKdlSimple*[T](node; dest: var T; errors; strict) =
  # This procedure cannot be hooked. Hook `deserializeKdl` instead.
  if (let n = node.args.deserializeKdlArgs dest; n >= 0):
    if strict:
      node.checkNoTag errors
      node.checkArgsMaxLen n, errors
      node.checkNoTagsInArgs n, errors
      node.checkNoProps errors
      node.checkNoChildren errors
  elif node.args.len != 0:
    errors &= formatInvalidValMsg(node, $T, node.args[0])
  else:
    errors &= formatMissingValMsg(node, $T)

template deserializeKdl*(
  node: KdlNode; dest: SimpleKdlVal | SeqOrSomeSet[SimpleKdlVal]; errors: seq[string]; strict: bool;
) =
  node.deserializeKdlSimple dest, errors, strict

proc deserializeKdl*(node; dest: var KdlDoc; errors; strict) =
  if strict:
    node.checkNoTag errors
    node.checkArgsMaxLen 0, errors
    node.checkNoProps errors
  dest &= node.children

proc deserializeKdl*[T: not SimpleKdlVal](node; dest: var Option[T]; errors; strict) =
  var x = if dest.isSome: move dest else: default T
  node.deserializeKdl x, errors, strict
  dest = some x

proc deserializeKdl*[T: not SimpleKdlVal](node; dest: var SeqOrSomeSet[T]; errors; strict) =
  var x: T
  node.deserializeKdl x, errors, strict
  dest &= x

func formatInvalidArgsMsg(node): string =
  &"Invalid arguments for node {BareNode node}."

proc deserializeKdlNodeArgs*(node; dest: var auto; errors; strict) =
  # This procedure cannot be hooked. Hook `getKdlArgsStorage` instead.
  let n = node.args.deserializeKdlArgs dest
  if n >= 0:
    if strict:
      node.checkArgsMaxLen n, errors
      node.checkNoTagsInArgs n, errors
  else:
    errors &= formatInvalidArgsMsg node

func formatInvalidPropMsg(node; ty, name: string; val: KdlVal): string =
  &"Invalid property for node {BareNode node}: expected {ty}, found {Quoted name}={val}."

func formatUnknownPropMsg(node; name: string; val: KdlVal): string =
  &"Unknown property for node {BareNode node}: {Quoted name}={val}."

proc deserializeKdlNodeProps*(node; dest: var auto; errors; strict) =
  # This procedure cannot be hooked. Hook `getKdlPropsStorage` instead.
  for propName, propVal in node.props.pairs:
    caseProp propName, dest, field:
      if propVal.deserializeKdlVal field:
        if strict:
          node.checkNoTag propVal, errors
      else:
        errors &= formatInvalidPropMsg(node, $typeOf field, propName, propVal)
    else:
      if strict:
        errors &= formatUnknownPropMsg(node, propName, propVal)

func formatUnknownNodeMsg(node; ty: string): string =
  &"Unknown node {BareNode node} in {ty}."

proc deserializeKdlNodeChild*[T: object](node; dest: var T; errors; strict) =
  # This procedure cannot be hooked. Hook `getKdlChildrenStorage` instead.
  caseChild node.name, dest, field:
    node.deserializeKdl field, errors, strict
  else:
    if strict:
      errors &= formatUnknownNodeMsg(node, $T)

proc deserializeKdlDoc*(doc: openArray[KdlNode]; dest: var KdlDoc; errors; strict) =
  dest &= doc

proc deserializeKdlDoc*(doc: openArray[KdlNode]; dest: var auto; errors; strict) =
  for node in doc:
    node.deserializeKdlNodeChild dest, errors, strict

proc deserializeKdl*(
  node; dest: var (not SimpleKdlVal and not SeqOrSomeSet[SimpleKdlVal]); errors; strict;
) =
  mixin getKdlArgsStorage, getKdlPropsStorage, getKdlChildrenStorage
  if strict:
    node.checkNoTag errors
  # `node.name` has been checked in `deserializeKdlNodeChild` so we ignore it here.
  node.deserializeKdlNodeArgs getKdlArgsStorage dest, errors, strict
  node.deserializeKdlNodeProps getKdlPropsStorage dest, errors, strict
  node.children.deserializeKdlDoc getKdlChildrenStorage dest, errors, strict
