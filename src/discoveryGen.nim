import std/options
import std/sets

type
  HashSetPatchMode* = enum
    hspmAllBut, hspmOnly

  HashSetPatch*[T] = object
    mode*: HashSetPatchMode
    elems*: HashSet[T]

proc genDiscoveryApis*(
  config: string;
  apiRoot = none string;
  targetRoot = none string;
  apis = default HashSetPatch[string];
  targets = default HashSetPatch[string];
) =
  echo repr config, '\n', apiRoot, '\n', targetRoot, '\n', apis, '\n', targets
