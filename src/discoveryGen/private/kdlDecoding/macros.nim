import std/macros
import std/sets

template getKdlFieldNames*(T: type; field: string): seq[string] = @[field]
template getKdlArgFields*(T: type): seq[string] = @[]
template getKdlPropFields*(T: type): seq[string] = @[]

macro withEachArgFieldAux(obj: typed; fieldNames: static openArray[string]; body: typed{nkSym}) =
  result = newStmtList()
  for field in fieldNames:
    result.add body.newCall obj.newDotExpr ident field

template withEachArgField*[T](obj: T; field, body: untyped) =
  mixin getKdlArgFields
  template body1(field) {.genSym.} = body
  withEachArgFieldAux obj, static getKdlArgFields T, body1

macro buildCaseStmt(
  fieldName: string; exprs: static openArray[seq[string]]; bodies: varargs[untyped];
): untyped =
  bodies.expectLen exprs.len + 1
  result = nnkCaseStmt.newTree fieldName
  for i, group in exprs:
    if group.len != 0:
      let branch = nnkOfBranch.newNimNode
      for expr in group:
        branch.add newLit expr
      result.add branch.add bodies[i]
  result.add bodies[^1]

macro casePropAux(
  fieldName: string;
  tySym: type{nkSym};
  obj: typed;
  fieldNames: static openArray[string];
  ofBodySym: typed{nkSym};
  elseBranch: untyped{nkElse};
): untyped =
  let bracket = nnkBracket.newNimNode
  let getKdlFieldNamesSym = bindSym("getKdlFieldNames", brForceOpen)

  result = bindSym"buildCaseStmt".newCall(fieldName, bindSym"static".newCall bracket)
  for s in fieldNames:
    bracket.add getKdlFieldNamesSym.newCall(tySym, newLit s)
    result.add ofBodySym.newCall obj.copyNimTree.newDotExpr ident s

  result.add elseBranch

template caseProp*[T](fieldName: string; obj: T; field, body, elseBranch: untyped): untyped =
  mixin getKdlPropFields
  template ofBody(field) {.genSym.} = body
  casePropAux fieldName, T, obj, static getKdlPropFields T, ofBody, elseBranch

macro caseChildAux(
  fieldName: string;
  tySym: type{nkSym};
  obj: typed;
  excludedFields: static openArray[string];
  ofBodySym: typed{nkSym};
  elseBranch: untyped{nkElse};
): untyped =
  var excluded: HashSet[string]
  for s in excludedFields:
    if excluded.containsOrIncl s:
      error "field " & s & " is listed multiple times by getKdlArgFields or getKdlPropFields", obj

  let
    bracket = nnkBracket.newNimNode
    getKdlFieldNamesSym = bindSym("getKdlFieldNames", brForceOpen)
    ty = obj.getType
  ty.expectKind nnkObjectTy

  result = bindSym"buildCaseStmt".newCall(fieldName, bindSym"static".newCall bracket)
  for sym in ty[2]:
    if sym.strVal not_in excluded:
      bracket.add getKdlFieldNamesSym.newCall(tySym, newLit sym.strVal)
      result.add ofBodySym.newCall obj.copyNimTree.newDotExpr sym

  result.add elseBranch

template caseChild*[T](fieldName: string; obj: T; field, body, elseBranch: untyped): untyped =
  ## Generate a `case` expression on `fieldName` matching those fields of `obj` that should
  ## be encoded as child nodes in KDL.
  mixin getKdlArgFields, getKdlPropFields
  template ofBody(field) {.genSym.} = body
  caseChildAux(
    fieldName, T, obj, static getKdlArgFields(T) & getKdlPropFields(T), ofBody, elseBranch,
  )
