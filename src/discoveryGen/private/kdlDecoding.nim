from ./kdlDecoding/decoding import KdlError, KdlNode, deserializeKdl, deserializeKdlDoc

export decoding

type KdlDeserializationError* = object of KdlError
  errors*: seq[string]

func raiseErrors(errors: sink seq[string]) {.noReturn, noInline.} =
  raise (ref KdlDeserializationError)(msg: "Cannot deserialize KDL", errors: errors)

proc deserializeKdlDoc*(doc: openArray[KdlNode]; obj: var auto; strict: bool) =
  var errors: seq[string]
  doc.deserializeKdlDoc obj, errors, strict
  if errors.len != 0:
    raiseErrors errors

proc deserializeKdlDoc*(doc: openArray[KdlNode]; T: type; strict: bool): T =
  doc.deserializeKdlDoc result, strict

proc deserializeKdl*(node: KdlNode; obj: var auto; strict: bool) =
  var errors: seq[string]
  node.deserializeKdl obj, errors, strict
  if errors.len != 0:
    raiseErrors errors

proc deserializeKdl*(node: KdlNode; T: type; strict: bool): T =
  node.deserializeKdl result, strict
