import std/strformat
from   kdl/nodes import isInt
from   ./kdlDecoding/decoding import KdlError, KdlNode, deserializeKdl, deserializeKdlDoc

export decoding

type
  KdlDeserializationError* = object of KdlError
    errors*: seq[string]

  Version = object
    major, minor: int64

func raiseErrors(errors: sink seq[string]) {.noReturn, noInline.} =
  raise (ref KdlDeserializationError)(msg: "Cannot deserialize KDL", errors: errors)

proc deserializeKdlDoc*(doc: openArray[KdlNode]; dest: var auto; strict: bool) =
  var errors: seq[string]
  doc.deserializeKdlDoc dest, errors, strict
  if errors.len != 0:
    raiseErrors errors

proc deserializeKdl*(node: KdlNode; dest: var auto; strict: bool) =
  var errors: seq[string]
  node.deserializeKdl dest, errors, strict
  if errors.len != 0:
    raiseErrors errors

proc deserializeKdlDoc*(
  doc: openArray[KdlNode]; T: type; errors: var seq[string]; strict: bool;
): T =
  doc.deserializeKdlDoc result, errors, strict

proc deserializeKdlDoc*(doc: openArray[KdlNode]; T: type; strict: bool): T =
  doc.deserializeKdlDoc result, strict

proc deserializeKdl*(node: KdlNode; T: type; errors: var seq[string]; strict: bool): T =
  node.deserializeKdl result, errors, strict

proc deserializeKdl*(node: KdlNode; T: type; strict: bool): T =
  node.deserializeKdl result, strict

proc checkKdlVersionNode*(
  node: KdlNode; nodeName: string; major, minor: int64; errors: var seq[string];
): bool =
  if node.name == nodeName and node.args.len != 0 and node.args[0].isInt and (block:
    if node.args[0].num != major:
      errors &= &"Wrong major version: expected {major}, found {node.args[0].num}."
      return false
    node.args.len != 1 and node.args[1].isInt and node.args[1].num >= 0
  ):
    node.args[1].num <= minor
  else:
    errors &= &"The first directive must be `{nodeName} {major} {minor}`."
    false

template getKdlArgFields(T: type Version): seq[string] =
  @["major", "minor"]

proc deserializeKdlDocWithVersion*(
  doc: openArray[KdlNode];
  dest: var auto;
  nodeName: string;
  major, minor: int64;
  errors: var seq[string];
): bool =
  bind getKdlArgFields
  if doc.len == 0:
    errors &= "The document is empty."
  elif errors.len == (
    let strict = doc[0].checkKdlVersionNode(nodeName, major, minor, errors);
    errors.len
  ):
    if strict:
      result = true
      discard doc[0].deserializeKdl(Version, errors, strict = true)
    doc.toOpenArray(1, doc.high).deserializeKdlDoc(dest, errors, strict)

proc deserializeKdlDocWithVersion*(
  doc: openArray[KdlNode]; dest: var auto; nodeName: string; major, minor: int64;
): bool =
  var errors: seq[string]
  result = doc.deserializeKdlDocWithVersion(dest, nodeName, major, minor, errors)
  if errors.len != 0:
    raiseErrors errors
