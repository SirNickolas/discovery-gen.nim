version     = "0.1.0"
author      = "Nickolay Bukreyev"
description = "Generate an API in a language of your choice from a Google Discovery document"
license     = "MIT"

requires(
  "nim >= 2.0.0",
  "cligen >= 1.5.0",
  "jsony >= 1.1.0",
  "kdl >= 2.0.0",
  "questionable >= 0.10.0",
  "sourcegens >= 0.1.4",
)

srcDir = "src"
binDir = "bin"
installExt = @["nim"]
namedBin["discoveryGen/cli"] = "discovery-gen"
