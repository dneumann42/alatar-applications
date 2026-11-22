# Package

version       = "0.1.0"
author        = "dneumann42"
description   = "A systemd ui"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["systemdui"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.4.2"
requires "chroma >= 1.0.0"

switch("stackTrace", "on")
switch("lineTrace", "on")
switch("excessiveStackTrace", "on")
switch("debugger", "native")
switch("ic", "on")
