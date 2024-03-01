version     = "0.1.0"
author      = "Nickolay Bukreyev"
description = "Generate an API in a language of your choice from a Google Discovery document"
license     = "MIT"

requires(
  "nim >= 1.6.0",
  "cligen >= 1.5.0",
  "kdl >= 2.0.0",
  "sourcegens >= 0.1.0",
)

srcDir = "src"
binDir = "bin"
installExt = @["nim"]
namedBin["discoveryGen/cli"] = "discovery-gen"
