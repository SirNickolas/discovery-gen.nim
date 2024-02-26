version     = "0.1.0"
author      = "Nickolay Bukreyev"
description = "Generate an API in a language of your choice from a Google Discovery document"
license     = "MIT"

requires(
  "nim >= 1.6.14",
  "sourcegens >= 0.1.0",
)

srcDir = "src"
binDir = "bin"
installExt = @["nim"]
namedBin["discoveryGen"] = "discovery-gen"
