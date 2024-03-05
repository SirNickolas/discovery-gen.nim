import std/sets
import std/tables
from   ../../backends import BackendError
from   ../../rawDiscovery import DiscoveryJsonSchema, DiscoveryRestDescription

type
  Settings* = object
    pathPattern*, package*: string

  Context* = ref object
    api*: DiscoveryRestDescription
    settings*: Settings
    needsJson*: bool
    jsonAliases*: HashSet[string]

using c: Context

proc processStruct(c; schema: DiscoveryJsonSchema) =
  case schema.`type`:
    of "any":
      c.needsJson = true
      c.jsonAliases.incl schema.id
    of "object":
      discard
    else:
      raise newException(BackendError, "Unexpected type \"" & schema.`type` & '"')

proc prepare*(c) {.tags: [].} =
  for schema in c.api.schemas.values:
    c.processStruct schema
