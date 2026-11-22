import std/[algorithm, json, os, sequtils, streams, strutils, times]
import systemdfile
import ./[systemdIO, timerValues, unitEditor]

type
  RecipeValueKind* = enum
    rvText, rvCommand, rvPath, rvDuration, rvCalendar, rvToggle
  RecipeValue* = object
    case
    of TextValue:
      text*: string
    of CommandValue:
      command*: string
    of PathValue:
      path*: string
    of DurationSetting:
      duration*: DurationValue
    of CalendarSetting:
      schedule*: CalendarSchedule
    of ToggleSetting:
      enabled*: bool

  RecipeInput* = object
    id*, label*, hint*: string
    defaultValue*: RecipeValue
    required*: bool

  RecipeSource = object
    case
    of LiteralValue:
      text: string
    of InputReference:
      field: int
    of UnitReference:
      unitKind: SystemdFileKind
    of StartupTarget:
      discard

  RecipeDirective = object
    section, key: string
    source: RecipeSource

  RecipeUnit = object
    kind: SystemdFileKind
    directives: seq[RecipeDirective]

  Recipe* = object
    title*, description*, activation*: string
    systemOnly*: bool
    inputs*: seq[RecipeInput]
    units: seq[RecipeUnit]

  RecipeCatalog* = object
    recipes*: seq[Recipe]
    errors*: seq[string]

  RecipeDraft* = object
    recipe*: Recipe
    name*, description*: string
    system*: bool
    values*: seq[RecipeValue]

proc invalid(message: string) {.noreturn.} =
  raise newException(ValueError, message)

func recipeDirectory*(): string =
  getConfigDir() / "systemdui" / "recipes"

func valueKind*(value: RecipeValue): RecipeValueKind =
  case value
  of TextValue(_): rvText
  of CommandValue(_): rvCommand
  of PathValue(_): rvPath
  of DurationSetting(_): rvDuration
  of CalendarSetting(_): rvCalendar
  of ToggleSetting(_): rvToggle

func isText(kind: RecipeValueKind): bool =
  kind in {rvText, rvCommand, rvPath}

proc readMember(node: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != kind:
    invalid("Expected " & key & " (" & $kind & ").")
  node[key]

proc readText(node: JsonNode, key: string): string =
  result = node.readMember(key, JString).getStr().strip()
  if result.len == 0:
    invalid(key & " cannot be blank.")

proc readKind(node: JsonNode, key: string): SystemdFileKind =
  result = unitKind("recipe." & node.readText(key))
  if result notin EditableUnitKinds:
    invalid("Unsupported unit type: " & $result)

proc readInput(node: JsonNode): RecipeInput =
  result.id = node.readText("id")
  result.label = node.readText("label")
  if node.hasKey("hint"):
    result.hint = node.readMember("hint", JString).getStr()
  result.required = not node.hasKey("required") or node.readMember("required", JBool).getBool()
  let kind = case node.readText("type")
    of "text": rvText
    of "command": rvCommand
    of "path": rvPath
    of "duration": rvDuration
    of "calendar": rvCalendar
    of "toggle": rvToggle
    else: invalid("Unknown input type for " & result.id)
  let value = node{"default"}
  case kind
  of rvText, rvCommand, rvPath:
    if value != nil and value.kind != JString:
      invalid(result.id & " needs a text default.")
    let text = value.getStr()
    result.defaultValue = case kind
      of rvCommand: CommandValue(command: text)
      of rvPath: PathValue(path: text)
      else: TextValue(text: text)
  of rvDuration:
    var duration = DurationValue(amount: 10, unit: DurationUnit.seconds)
    if value != nil:
      let amount = value.readMember("amount", JInt).getBiggestInt()
      if amount notin 1..99999:
        invalid(result.id & " must be between 1 and 99999.")
      var unit: DurationUnit
      case value.readText("unit")
      of "seconds": unit = DurationUnit.seconds
      of "minutes": unit = DurationUnit.minutes
      of "hours": unit = DurationUnit.hours
      of "days": unit = DurationUnit.days
      else: invalid(result.id & " needs a duration unit.")
      duration = DurationValue(amount: int(amount), unit: unit)
    result.defaultValue = DurationSetting(duration: duration)
  of rvCalendar:
    var calendar = CalendarSchedule(time: TimeOfDay(hour: 9))
    if value != nil:
      let frequency = value.readText("frequency")
      case frequency
      of "daily": calendar.pattern = Daily()
      of "weekdays": calendar.pattern = BusinessDays()
      of "weekly":
        let day = value.readMember("weekday", JInt).getBiggestInt()
        if day notin 1..7:
          invalid(result.id & " needs a weekday between 1 (Monday) and 7 (Sunday).")
        calendar.pattern = Weekly(weekday: WeekDay(day - 1))
      of "date":
        let year = value.readMember("year", JInt).getBiggestInt()
        let month = value.readMember("month", JInt).getBiggestInt()
        let day = value.readMember("day", JInt).getBiggestInt()
        if year notin 1970..9999 or month notin 1..12 or
            day notin 1..getDaysInMonth(Month(month), int(year)):
          invalid(result.id & " has an invalid date.")
        calendar.pattern = SpecificDate(date: CalendarDate(year: int(year),
          month: Month(month), day: int(day)))
      else: invalid(result.id & " needs daily, weekdays, weekly, or date.")
      let hour = value.readMember("hour", JInt).getBiggestInt()
      let minute = value.readMember("minute", JInt).getBiggestInt()
      if hour notin 0..23 or minute notin 0..59:
        invalid(result.id & " has an invalid clock time.")
      calendar.time = TimeOfDay(hour: int(hour), minute: int(minute))
    result.defaultValue = CalendarSetting(schedule: calendar)
  of rvToggle:
    if value != nil and value.kind != JBool:
      invalid(result.id & " needs a boolean default.")
    result.defaultValue = ToggleSetting(enabled: value.getBool())

func compatible(kind: RecipeValueKind, section, key: string): bool =
  if section == "Timer":
    if key == "OnCalendar": return kind == rvCalendar
    if key.timerDurationKey(): return kind == rvDuration
    if key in ["Persistent", "WakeSystem"]: return kind == rvToggle
  if section == "Service" and key == "RestartSec":
    return kind == rvDuration
  if section == "Service" and key in ["ExecStart", "ExecStop", "ExecReload"]:
    return kind == rvCommand
  if (section == "Path" and key in ["PathChanged", "PathModified", "PathExists",
      "PathExistsGlob", "DirectoryNotEmpty"]) or (section == "Service" and
      key == "WorkingDirectory") or (section in ["Mount", "Automount"] and key == "Where") or
      (section == "Swap" and key == "What"):
    return kind == rvPath
  true

proc parseRecipe*(definition: string): Recipe =
  let root = parseJson(definition)
  if root.readMember("version", JInt).getInt() != 1:
    invalid("Unsupported recipe version.")
  result.title = root.readText("title")
  result.description = root.readText("description")
  if root.hasKey("activation"):
    result.activation = root.readMember("activation", JString).getStr()
  if root.hasKey("systemOnly"):
    result.systemOnly = root.readMember("systemOnly", JBool).getBool()
  var indices: Table[string, int]
  for field in root.readMember("inputs", JArray).items:
    let parsed = readInput(field)
    if parsed.id in indices:
      invalid("Duplicate input: " & parsed.id)
    indices[parsed.id] = result.inputs.len
    result.inputs.add parsed
  var references, kinds: set[SystemdFileKind]
  for entry in root.readMember("units", JArray).items:
    let kind = entry.readKind("type")
    if kind in kinds:
      invalid("Duplicate output unit type: " & $kind)
    kinds.incl kind
    var unit = RecipeUnit(kind: kind)
    if kind in {Mount, Automount, Swap}:
      result.systemOnly = true
    for item in entry.readMember("directives", JArray).items:
      let section = item.readText("section")
      let key = item.readText("key")
      if key.anyIt(it notin Letters + Digits):
        invalid("Invalid directive name: " & key)
      if section notin ["Unit", "Install"] and (kind == Target or section.toLowerAscii() != $kind):
        invalid("Invalid section [" & section & "] for a " & $kind & " unit.")
      let value = item.readMember("value", JObject)
      if value.len != 1:
        invalid("Specify one value source for " & key & ".")
      let source =
        if value.hasKey("text"):
          LiteralValue(text: value.readMember("text", JString).getStr())
        elif value.hasKey("input"):
          let id = value.readText("input")
          if id notin indices:
            invalid("Unknown input: " & id)
          let index = indices[id]
          if not compatible(result.inputs[index].defaultValue.valueKind(), section, key):
            invalid(id & " has the wrong input type for " & key & ".")
          InputReference(field: index)
        elif value.hasKey("unit"):
          let target = value.readKind("unit")
          references.incl target
          UnitReference(unitKind: target)
        elif value{"startupTarget"}.getBool():
          StartupTarget()
        else:
          invalid("Unknown value source for " & key & ".")
      unit.directives.add RecipeDirective(section: section, key: key, source: source)
    result.units.add unit
  if result.units.len == 0:
    invalid("A recipe must generate at least one unit.")
  if not (references <= kinds):
    invalid("A unit reference points to a unit the recipe does not generate.")

proc newRecipeDraft*(recipe: Recipe, system: bool): RecipeDraft =
  RecipeDraft(recipe: recipe, system: system or recipe.systemOnly,
    values: recipe.inputs.mapIt(it.defaultValue))

func rendered(value: RecipeValue): string =
  case value
  of TextValue(text): text.strip()
  of CommandValue(command): command.strip()
  of PathValue(path): path.strip()
  of DurationSetting(duration): duration.durationText()
  of CalendarSetting(schedule): schedule.calendarText()
  of ToggleSetting(enabled): (if enabled: "yes" else: "no")

func inputError*(input: RecipeInput, value: RecipeValue): string =
  let kind = value.valueKind()
  if input.defaultValue.valueKind() != kind:
    return input.label & " has the wrong input type."
  if kind.isText:
    let text = value.rendered()
    if input.required and text.len == 0:
      return "Enter " & input.label.toLowerAscii() & "."
    if kind == rvPath and text.len > 0 and not text.isAbsolute:
      return input.label & " needs an absolute path."

proc recipeStem*(name: string): string =
  result = name.strip()
  if result.len == 0 or result.len > 240 or result.anyIt(it notin Letters + Digits + {'-', '_'}):
    invalid("Enter a unit name of up to 240 characters using letters, numbers, hyphens, or underscores.")

proc renderRecipe*(draft: RecipeDraft): seq[GeneratedUnit] =
  let stem = recipeStem(draft.name)
  if draft.values.len != draft.recipe.inputs.len or (draft.recipe.systemOnly and not draft.system):
    invalid("The recipe settings are incomplete.")
  for index, field in draft.recipe.inputs:
    let error = inputError(field, draft.values[index])
    if error.len > 0:
      invalid(error)

  # Resolve path-derived names first so other generated units can refer to them.
  var names: array[SystemdFileKind, string]
  for unit in draft.recipe.units:
    var namingDocument = SystemdFile()
    for directive in unit.directives:
      if (unit.kind in {Mount, Automount} and directive.key == "Where") or
          (unit.kind == Swap and directive.key == "What"):
        let source = directive.source
        let value = case source
          of LiteralValue(text): text
          of InputReference(field): draft.values[field].rendered()
          else: invalid("A path-derived unit name needs a path value.")
        namingDocument.entries.add Section(name: directive.section)
        namingDocument.entries.add Directive(key: directive.key, value: value)
    let namingContent = newStringStream()
    namingContent.writeSystemdFile(namingDocument)
    names[unit.kind] = UnitDraft(kind: unit.kind, name: stem,
      system: draft.system).unitName(namingContent.data)

  for unit in draft.recipe.units:
    var sections: OrderedTable[string, seq[SystemdEntry]]
    let description = if draft.description.strip().len > 0: draft.description.strip()
                      else: draft.recipe.title & " (" & stem & ")"
    if not unit.directives.anyIt(it.section == "Unit" and it.key == "Description"):
      sections.mgetOrPut("Unit", @[]).add Directive(key: "Description", value: description)
    for directive in unit.directives:
      let source = directive.source
      let value = case source
        of LiteralValue(text): text
        of InputReference(field): draft.values[field].rendered()
        of UnitReference(kind): names[kind]
        of StartupTarget(): (if draft.system: "multi-user.target" else: "default.target")
      case source
      of InputReference(_):
        if value.len == 0:
          continue
      else:
        discard
      sections.mgetOrPut(directive.section, @[]).add Directive(key: directive.key, value: value)
    var document: SystemdFile
    for section, entries in sections:
      if document.entries.len > 0:
        document.entries.add BlankLine()
      document.entries.add Section(name: section)
      document.entries.add entries
    let stream = newStringStream()
    stream.writeSystemdFile(document)
    result.add (names[unit.kind], stream.data)

const BuiltInRecipes = [
  staticRead("../../recipes/repeat-command.json"),
  staticRead("../../recipes/calendar-command.json"),
  staticRead("../../recipes/startup-delay.json"),
  staticRead("../../recipes/path-changed.json"),
  staticRead("../../recipes/path-exists.json"),
  staticRead("../../recipes/background-service.json"),
  staticRead("../../recipes/startup-command.json")
]

proc loadRecipes*(): RecipeCatalog =
  for definition in BuiltInRecipes:
    result.recipes.add parseRecipe(definition)
  var files: seq[string]
  for path in walkFiles(recipeDirectory() / "*.json"):
    files.add path
  files.sort()
  for path in files:
    try:
      result.recipes.add parseRecipe(readFile(path))
    except CatchableError as error:
      result.errors.add path.extractFilename() & ": " & error.msg
