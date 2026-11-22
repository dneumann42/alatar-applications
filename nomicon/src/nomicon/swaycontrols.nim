import std/[json, os, strutils]
import alatar/controls

type
  DisplayOutput* = object
    name*: string
    active*: bool
    power*: bool
    x*, y*, width*, height*: int
    transform*: string

## --- display ----------------------------------------------------------------------

func jsonField(o: JsonNode, key: string): JsonNode =
  if o.kind == JObject:
    for k, v in o.pairs:
      if k == key:
        return v
  nil

func jStr(o: JsonNode, key: string): string =
  let v = o.jsonField(key)
  if v != nil and v.kind == JString: v.str else: ""

func jBool(o: JsonNode, key: string): bool =
  let v = o.jsonField(key)
  v != nil and v.kind == JBool and v.bval

func jInt(o: JsonNode, key: string): int =
  let v = o.jsonField(key)
  if v != nil and v.kind == JInt: int(v.num) else: 0

proc parseSwayJson(raw: string): JsonNode {.raises: [ControlError].} =
  try:
    result = parseJson(raw)
  except CatchableError as e:
    raise newException(ControlError, "swaymsg returned invalid JSON: " & e.msg, e)

proc swayOutputs*(): seq[DisplayOutput] {.raises: [ControlError].} =
  let tree = parseSwayJson(runOk("swaymsg", @["-t", "get_outputs"]))
  if tree.kind != JArray:
    raise newException(ControlError, "swaymsg get_outputs: expected a JSON array")
  for o in tree:
    let name = o.jStr("name")
    if name.len == 0 or o.jBool("non_desktop"):
      continue
    let rect = o.jsonField("rect")
    result.add DisplayOutput(
      name: name,
      active: o.jBool("active"),
      power: o.jBool("power"),
      x: if rect != nil: rect.jInt("x") else: 0,
      y: if rect != nil: rect.jInt("y") else: 0,
      width: if rect != nil: rect.jInt("width") else: 0,
      height: if rect != nil: rect.jInt("height") else: 0,
      transform: o.jStr("transform"))

proc swayConfig*(): string {.raises: [ControlError].} =
  parseSwayJson(runOk("swaymsg", @["-t", "get_config"])).jStr("config")

## Quoting the name keeps connector identifiers with spaces intact; sway
## output names never contain quotes themselves.
proc setOutputEnabled*(name: string, enabled: bool) {.raises: [ControlError].} =
  discard runOk("swaymsg",
    @["output \"" & name & "\" " & (if enabled: "enable" else: "disable")])

## The sway config directory, where the user's keybinding scripts live.
proc swayConfigDir(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".config") / "sway"

func swayScriptsDir*(): string =
  swayConfigDir() / "scripts"

## Runs a script from ~/.config/sway/scripts the way the keybinding that
## calls it does: through sway's own `exec`, so it inherits the compositor
## environment instead of whatever the calling app happens to have.
## `set-wallpaper.sh` is the wallpaper switcher bound to Shift+Mod4+w.
proc swayExecScript*(name: string) {.raises: [ControlError].} =
  let path = swayScriptsDir() / name
  if not fileExists(path):
    raise newException(ControlError, "Missing sway script: " & path)
  discard runOk("swaymsg", @["exec " & path])

## A disabled output reports a 0x0 rect and drops its transform, so after a
## `sway reload` or a nomicon toggle the portrait screen cannot be recognized
## from get_outputs alone. swaymsg -t get_config only returns the top-level
## file (includes are not expanded), so scan the sway config directory for
## `output <name> ... transform <90|270>` instead: the vertical monitor is
## the one sway physically rotates. (swayConfigDir is defined above.)
func isPortraitTransform(value: string): bool =
  value in ["90", "270", "flipped-90", "flipped-270"]

func rotatedNameInLine(line: string): string =
  let toks = line.strip().split(maxSplit = 1)
  if toks.len < 2 or toks[0] != "output":
    return ""
  var words: seq[string] = @[]
  var rest = toks[1]
  var quoted = false
  var value = ""
  for c in rest:
    if c == '"':
      quoted = not quoted
    elif c == ' ' and not quoted:
      if value.len > 0:
        words.add value
        value = ""
    else:
      value.add c
  if value.len > 0:
    words.add value
  if words.len < 2:
    return ""
  var i = 1
  while i < words.len:
    if words[i] == "transform" and i + 1 < words.len and
        words[i + 1].isPortraitTransform():
      return words[0]
    inc i
  ""

proc rotatedOutputNames*(): seq[string] =
  let dir = swayConfigDir()
  if not dirExists(dir):
    return @[]
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    let text = try: readFile(path) except CatchableError: continue
    for line in text.splitLines():
      let name = line.rotatedNameInLine()
      if name.len > 0 and name notin result:
        result.add name
