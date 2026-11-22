import std/[cmdline, os, osproc, sequtils, streams, strutils, tempfiles]
import systemdfile
import ./[systemdIO]

type
  GeneratedUnit* = tuple[name, content: string]

  UnitField* = object
    section*, key*, label*, hint*: string
    value*, original*: string
    occurrences*: int

  UnitDraft* = object
    kind*: SystemdFileKind
    name*: string
    system*: bool
    source*, original*, content*: string
    fields*: seq[UnitField]

func field(section, key, label, hint: string): UnitField =
  UnitField(section: section, key: key, label: label, hint: hint)

func unitFields(kind: SystemdFileKind, system: bool): seq[UnitField] =
  result.add field("Unit", "Description", "Description", "A short explanation of this unit")
  case kind
  of Service:
    result.add field("Service", "ExecStart", "Command", "/usr/bin/my-program --option")
    result.add field("Service", "Type", "Service type", "simple, exec, oneshot, notify… (default: automatic)")
    result.add field("Service", "WorkingDirectory", "Working directory", "/absolute/path")
    result.add field("Service", "Restart", "Restart policy", "no, on-failure, always… (default: no)")
  of Timer:
    result.add field("Timer", "OnCalendar", "Calendar schedule", "")
    result.add field("Timer", "OnActiveSec", "Delay after timer starts", "")
    result.add field("Timer", "OnBootSec", "Delay after boot", "")
    result.add field("Timer", "OnUnitActiveSec", "Repeat after activation", "")
    result.add field("Timer", "AccuracySec", "Timing accuracy", "")
    result.add field("Timer", "Unit", "Unit to run", "my-job.service (default: same name)")
  of Socket:
    result.add field("Socket", "ListenStream", "Stream address", "127.0.0.1:8080 or /run/my-app.sock")
    result.add field("Socket", "ListenDatagram", "Datagram address", "127.0.0.1:5353")
    result.add field("Socket", "Service", "Service to start", "my-app.service (default: same name)")
  of Path:
    result.add field("Path", "PathChanged", "Watch for changes", "/absolute/path")
    result.add field("Path", "PathExists", "Watch for existence", "/absolute/path")
    result.add field("Path", "Unit", "Unit to run", "my-job.service (default: same name)")
  of Target:
    result.add field("Unit", "Wants", "Units to group", "one.service two.service")
    result.add field("Unit", "After", "Start after", "other.target")
  of Mount:
    result.add field("Mount", "Where", "Mount point", "/mnt/data")
    result.add field("Mount", "What", "Device or remote source", "/dev/disk/by-label/data")
    result.add field("Mount", "Type", "Filesystem", "ext4, xfs, nfs…")
    result.add field("Mount", "Options", "Mount options", "defaults")
  of Automount:
    result.add field("Automount", "Where", "Mount point", "/mnt/data")
    result.add field("Automount", "TimeoutIdleSec", "Unmount after idle", "")
  of Swap:
    result.add field("Swap", "What", "Swap device or file", "/swapfile")
    result.add field("Swap", "Priority", "Priority", "100")
    result.add field("Swap", "Options", "Swap options", "discard")
  of Slice:
    result.add field("Slice", "CPUWeight", "CPU weight", "1–10000 (default: 100)")
    result.add field("Slice", "MemoryMax", "Memory limit", "512M, 2G, or infinity")
    result.add field("Slice", "TasksMax", "Maximum tasks", "128 or infinity")
  else:
    discard
  let defaultTarget =
    if not system: "default.target"
    elif kind == Timer: "timers.target"
    elif kind == Socket: "sockets.target"
    elif kind == Path: "paths.target"
    elif kind in {Mount, Automount}: "local-fs.target"
    elif kind == Swap: "swap.target"
    else: "multi-user.target"
  result.add field("Install", "WantedBy", "Enable under", defaultTarget & " (optional)")

proc loadFields*(draft: var UnitDraft) =
  let document = newStringStream(draft.content).readSystemdFile()
  var fields = unitFields(draft.kind, draft.system)
  var section: string
  for entry in document.entries:
    case entry
    of Section(name):
      section = name
    of Directive(key, value):
      for setting in fields.mitems:
        if section == setting.section and key == setting.key:
          inc setting.occurrences
          setting.value = value
          setting.original = value
    else:
      discard
  draft.fields = fields

proc newDraft*(kind: SystemdFileKind, system: bool): UnitDraft =
  result = UnitDraft(kind: kind, system: system)
  result.loadFields()

proc editDraft*(unit: SystemdService): UnitDraft =
  let source = expandFilename(unit.path)
  if source == "/dev/null":
    raise newException(ValueError, "This unit is masked. Unmask it before editing.")
  result = UnitDraft(kind: unitKind(source.extractFilename()), system: unit.system,
    name: source.extractFilename(), source: source, original: readFile(source))
  result.content = result.original

proc formContent*(draft: UnitDraft): string =
  var changed = false
  for setting in draft.fields:
    if setting.value != setting.original:
      changed = true
  if not changed:
    return draft.content

  var spans: seq[EntrySpan]
  let document = newStringStream(draft.content).readSystemdFile(spans)
  var section: string
  var start = 0
  for index, entry in document.entries:
    case entry
    of Section(name):
      section = name
    of Directive(key, _):
      for setting in draft.fields:
        if setting.occurrences == 1 and setting.section == section and setting.key == key and
            setting.value != setting.original:
          let span = spans[index]
          result.add draft.content[start ..< span.first]
          if setting.value.strip().len > 0:
            result.add formatEntry(Directive(key: key, value: setting.value), index + 1)
          start = span.pastLast
          break
    else:
      discard
  result.add draft.content[start .. ^1]

  var additions: OrderedTable[string, seq[string]]
  for setting in draft.fields:
    if setting.occurrences == 0 and setting.value.strip().len > 0:
      additions.mgetOrPut(setting.section, @[]).add(
        formatEntry(Directive(key: setting.key, value: setting.value), 1))
  for newSection, directives in additions:
    if result.len > 0:
      result.add "\n\n"
    result.add "[" & newSection & "]\n" & directives.join("\n") & "\n"

proc unitCommand(command: string, args: openArray[string]): string =
  let process = startProcess(command, args = args, options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let (lines, status) = process.readLines()
  result = lines.join("\n").strip()
  if status != 0:
    if result.len == 0:
      result = command & " exited with status " & $status
    raise newException(ValueError, result)

func pathKey(kind: SystemdFileKind): string =
  case kind
  of Mount, Automount: "Where"
  of Swap: "What"
  else: ""

func validUnitName(name: string): bool =
  let (directory, stem, extension) = name.splitFile()
  if directory.len > 0 or stem.len == 0 or stem in [".", ".."] or
      name.len > 255 or stem.count('@') > 1 or stem.startsWith("@") or
      name.anyIt(it notin {'a'..'z', 'A'..'Z', '0'..'9', ':', '_', '.', '-', '@', '\\'}):
    return false
  for kind in SystemdFileKind:
    if extension == "." & $kind:
      return true

proc unitName*(draft: UnitDraft, content: string): string =
  let key = pathKey(draft.kind)
  if draft.source.len == 0 and key.len > 0:
    var parsed = UnitDraft(kind: draft.kind, system: draft.system, content: content)
    parsed.loadFields()
    for setting in parsed.fields:
      if setting.key == key:
        let location = setting.value
        if not location.isAbsolute or setting.occurrences != 1:
          raise newException(ValueError, "Enter one absolute path in " & key & ".")
        result = unitCommand("systemd-escape", ["--path", "--suffix=" & $draft.kind,
          "--", location])
  else:
    result = draft.name.strip()
    let suffix = "." & $draft.kind
    if not result.endsWith(suffix):
      result.add suffix

  if not validUnitName(result):
    raise newException(ValueError, "Enter a unit name such as my-job." & $draft.kind &
      ". Use letters, numbers, hyphens, or underscores.")

proc unitDestination*(draft: UnitDraft): string =
  if draft.system: "/etc/systemd/system"
  else: getConfigDir() / "systemd" / "user"

proc validateUnitContent(content: string) =
  let document = newStringStream(content).readSystemdFile()
  if document.entries.len == 0 or content.strip().len == 0:
    raise newException(ValueError, "Enter the unit configuration before saving.")
  var section: string
  for entry in document.entries:
    case entry
    of Section(name):
      section = name
    of Directive(key, value):
      if section.len == 0:
        raise newException(ValueError, "Every setting must be inside a section such as [Unit].")
      # verify loads the unit, but install links are only used by systemctl enable.
      if section == "Install" and key in ["WantedBy", "RequiredBy", "UpheldBy", "Also", "Alias"]:
        for reference in parseCmdLine(value):
          if not validUnitName(reference) and ('%' notin reference or
              reference.anyIt(it in {'/', ' ', '\t'})):
            raise newException(ValueError, key & " needs unit names such as " &
              "multi-user.target. Invalid name: " & reference)
    else:
      discard
proc verifyUnits(units: openArray[GeneratedUnit], system: bool) =
  let directory = createTempDir("systemdui-verify-", "")
  defer: removeDir(directory)
  var args = @["--man=no", "--recursive-errors=no"]
  if not system:
    args.add "--user"
  args.add "verify"
  for unit in units:
    unit.content.validateUnitContent()
    let candidate = directory / unit.name
    writeFile(candidate, unit.content)
    args.add candidate
  try:
    discard unitCommand("systemd-analyze", args)
  except ValueError as error:
    raise newException(ValueError, error.msg.replace(directory & DirSep, ""))

proc verifyAvailable(names: openArray[string], system: bool) =
  for unit in listSystemdUnits():
    if unit.system == system and unit.name in names:
      raise newException(ValueError, unit.name & " already exists in the selected scope.")

proc stageUnit(directory, content: string): string =
  let (file, staging) = createTempFile(".systemdui-", ".tmp", directory)
  try:
    try:
      file.write(content)
      file.flushFile()
    finally:
      file.close()
  except CatchableError:
    removeFile(staging)
    raise
  result = staging

const UnitPermissions = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}

proc saveRecipeUnits*(units: openArray[GeneratedUnit], system: bool) =
  if units.len == 0:
    raise newException(ValueError, "The recipe did not generate any units.")
  var names: seq[string]
  for unit in units:
    if not validUnitName(unit.name) or unit.name in names:
      raise newException(ValueError, "The recipe generated an invalid or duplicate unit name.")
    names.add unit.name
  verifyAvailable(names, system)
  verifyUnits(units, system)
  let directory = UnitDraft(system: system).unitDestination()
  createDir(directory)
  var staged, published: seq[string]
  defer:
    for path in staged:
      removeFile(path)
  try:
    for unit in units:
      let staging = stageUnit(directory, unit.content)
      staged.add staging
      staging.setFilePermissions(UnitPermissions)
    for index, unit in units:
      let path = directory / unit.name
      createHardlink(staged[index], path)
      published.add path
  except CatchableError as error:
    for index, path in published:
      if fileExists(path) and getFileInfo(path, followSymlink = false).id ==
          getFileInfo(staged[index]).id:
        removeFile(path)
    raise error

proc saveUnit*(draft: UnitDraft, content: string): string =
  let name = draft.unitName(content)
  let directory = draft.unitDestination()
  result = directory / name
  let updating = draft.source == result
  if not updating:
    if fileExists(result) or symlinkExists(result):
      raise newException(ValueError, "A unit already exists at " & result & ". Reopen it to edit it.")
    if draft.source.len == 0:
      verifyAvailable([name], draft.system)
  verifyUnits([(name, content)], draft.system)
  createDir(directory)
  let staging = stageUnit(directory, content)
  defer: removeFile(staging)
  if updating:
    if symlinkExists(result) or readFile(result) != draft.original:
      raise newException(ValueError, "The unit changed on disk. Reopen it before editing.")
    staging.setFilePermissions(result.getFilePermissions())
    moveFile(staging, result)
  else:
    if draft.source.len > 0 and readFile(draft.source) != draft.original:
      raise newException(ValueError, "The original unit changed on disk. Reopen it before editing.")
    staging.setFilePermissions(UnitPermissions)
    createHardlink(staging, result)
