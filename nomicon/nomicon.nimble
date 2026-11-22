import std/tables

version       = "0.1.0"
description   = "Nomicon Settings for Alatar"
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
namedBin      = {"nomicon": "nomicon-settings", "launcher": "nomicon-launcher"}.toTable
binDir        = "bin"

requires "nim >= 2.4.0"

requires "chroma >= 1.0.0"
