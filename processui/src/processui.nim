import std/[algorithm, monotimes, os, posix, sets, strutils, tables, times, unicode]
import ellipse_ui
import ellipse_ui/keys
import ellipse/platform/platform
import alatar/[desktopchrome, desktopmode, desktoptheme]
import processes

const
  Columns = [
    tableColumn("Process", grow(245)),
    tableColumn("PID", fixedPx(80), align = right),
    tableColumn("UID", fixedPx(75), align = right),
    tableColumn("State", fixedPx(70)),
    tableColumn("CPU %", fixedPx(86), align = right),
    tableColumn("RSS MiB", fixedPx(92), align = right),
    tableColumn("Actions", fixedPx(160), sortable = false)
  ]
  OwnerOptions = ["All users", "My processes"]
  StateOptions = ["All states", "Running", "Sleeping", "Stopped", "Zombie", "Other"]
  ActionOptions = ["Actions", "Details", "Terminate", "Kill -9", "Suspend", "Resume", "pkill by name"]
  Signals = [0.cint, 0.cint, SIGTERM, SIGKILL, SIGSTOP, SIGCONT, SIGTERM]

type
  TreeRow = object
    process: Process
    depth: int
    branch, expanded, context: bool
  Manager = object
    processes: Snapshot
    sampled: MonoTime
    collapsed, expanded: HashSet[ProcessKey]
    expandDefault: bool
    query, notice: string
    owner, state, action: int
    sort: TableSort
    target: Process

var manager {.threadvar.}: Manager

func stateIndex(state: char): int =
  case state
  of 'R': 1
  of 'S', 'D', 'I': 2
  of 'T', 't': 3
  of 'Z': 4
  else: 5

func display(value: string): string =
  result = value.multiReplace(("\n", " "), ("\r", " "), ("\t", " "))
  if validateUtf8(result) != -1:
    for ch in result.mitems:
      if ord(ch) >= 128: ch = '?'

proc refresh() =
  let now = getMonoTime()
  let seconds = float((now - manager.sampled).inMilliseconds) / 1000
  manager.processes = snapshot(manager.processes, seconds)
  manager.sampled = now
  var live: HashSet[ProcessKey]
  for process in manager.processes.values: live.incl process.key
  manager.collapsed = manager.collapsed * live
  manager.expanded = manager.expanded * live

proc tree(): seq[TreeRow] =
  let query = unicode.toLower(display(manager.query.strip))
  let filtering = query.len > 0 or manager.owner != 0 or manager.state != 0
  var included, matches: HashSet[int]
  let ownUid = int(getuid())
  for pid, process in manager.processes:
    if manager.owner == 1 and process.owner != ownUid: continue
    if manager.state != 0 and stateIndex(process.state) != manager.state: continue
    if query.len > 0 and query notin unicode.toLower(display(process.name & " " &
        $pid & " " & process.command)): continue
    matches.incl pid
    var ancestor = pid
    while ancestor in manager.processes and ancestor notin included:
      included.incl ancestor
      ancestor = manager.processes[ancestor].parent

  var children: Table[int, seq[int]]
  for pid in included:
    let process = manager.processes[pid]
    let parent = manager.processes.getOrDefault(process.parent)
    let linked = parent.key.pid in included and parent.key.pid != pid and
      parent.key.started <= process.key.started
    children.mgetOrPut(if linked: parent.key.pid else: 0, @[]).add pid

  proc compare(a, b: int): int =
    let x = manager.processes[a]
    let y = manager.processes[b]
    result = case manager.sort.column
      of 0: cmpIgnoreCase(x.name, y.name)
      of 2: cmp(x.owner, y.owner)
      of 3: cmp(stateIndex(x.state), stateIndex(y.state))
      of 4: cmp(x.cpu, y.cpu)
      of 5: cmp(x.residentKiB, y.residentKiB)
      else: cmp(a, b)
    if manager.sort.descending: result = -result
    if result == 0: result = cmp(a, b)

  for group in children.mvalues: group.sort(compare)

  var pending: seq[tuple[pid, depth: int]]
  template pushChildren(parentId, depthValue: int) =
    if parentId in children:
      let group = children[parentId]
      for index in countdown(group.high, 0):
        pending.add (group[index], depthValue)
  pushChildren(0, 0)
  var visited: HashSet[int]
  while pending.len > 0:
    let (pid, depth) = pending.pop()
    if pid in visited: continue
    visited.incl pid
    let process = manager.processes[pid]
    let branch = pid in children
    let expanded = process.key notin manager.collapsed and
      (filtering or manager.expandDefault or process.key in manager.expanded)
    result.add TreeRow(process: process, depth: depth, branch: branch,
      expanded: expanded, context: pid notin matches)
    if branch and expanded: pushChildren(pid, depth + 1)

proc signalTargets(): seq[Process] =
  if manager.action != 6: return @[manager.target]
  for process in manager.processes.values:
    if process.owner == int(getuid()) and process.name == manager.target.name and
        process.key.pid > 1 and process.key.pid != int(getpid()):
      result.add process

proc perform(targets: seq[Process]) =
  var sent, failed = 0
  var lastError: string
  for process in targets:
    try:
      signalProcess(process, Signals[manager.action])
      inc sent
    except CatchableError as error:
      inc failed
      lastError = error.msg
  manager.notice = "Signaled " & $sent & (if sent == 1: " process." else: " processes.")
  if failed > 0:
    manager.notice.add " Failed for " & $failed & ". " & lastError
  manager.action = 0
  refresh()

widget ActionPanel():
  let target = manager.target
  let identity = display(target.name) & " (" & $target.key.pid & ")"
  container(col(width = grow(), padding = padAll(8), gap = 6).chrome(panel)):
    if manager.action == 1:
      text(identity & "   PPID " & $target.parent & "   UID " & $target.owner &
        "   " & StateOptions[stateIndex(target.state)])
      if target.command.len > 0:
        container(col(width = grow(), height = fixedPx(78))
            .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
          text(display(target.command))
    else:
      let targets = signalTargets()
      text(if manager.action == 6:
        "Terminate " & $targets.len & " of your processes named " & display(target.name) & "?"
      else: ActionOptions[manager.action] & " " & identity & "?")
      if targets.len > 0 and desktopButton(hashId("confirm-action"), "Confirm"):
        perform(targets)
    if desktopButton(hashId("cancel-action"), if manager.action == 1: "Done" else: "Cancel"):
      manager.action = 0

widget ProcessTable(id: ElementId, rows: seq[TreeRow], resetScroll: bool):
  const RowHeight = 32f
  let bodyId = tableBodyId(id)
  TableContainer(id, Columns):
    TableHead:
      for index, column in Columns:
        if TableHeaderCell(id, index, column, manager.sort):
          manager.sort = nextTableSort(manager.sort, index)
          invalidate()
    TableBody(id):
      let scroll = scrollContainerData(bodyId)
      let viewport = if scroll.found and scroll.containerDimensions.height > 0:
        scroll.containerDimensions.height else: 420f
      let offset = if resetScroll: 0f
        else: clamp(scroll.position.y, -max(0f, float32(rows.len) * RowHeight - viewport), 0f)
      if scroll.found and offset != scroll.position.y:
        setScrollPosition(bodyId, vec2(0, offset))
      let visible = tableVisibleRows(rows.len, RowHeight, viewport, offset)
      if rows.len == 0:
        container(col(width = grow(), padding = padAll(12))):
          tableText("No processes match your search and filters.", muted = true)
      if visible.first > 0:
        container(col(width = grow(), height = fixedPx(float32(visible.first) * RowHeight))): discard
      for index in visible.first ..< visible.last:
        let entry = rows[index]
        let process = entry.process
        let key = $process.key.pid & "." & $process.key.started
        let rowId = tableRowId(id, key)
        TableRow(rowId, index, RowHeight):
          TableCell(rowId, 0, Columns[0]):
            let indent = min(entry.depth, 10) * 12
            container(row(width = fixedPx(float32(indent)), height = grow())): discard
            if entry.branch:
              if desktopButton(elementId("branch." & key), if entry.expanded: "−" else: "+",
                  width = fixedPx(24), height = fixedPx(24), fontSize = activeTheme.text.caption):
                if entry.expanded:
                  manager.expanded.excl process.key
                  manager.collapsed.incl process.key
                else:
                  manager.collapsed.excl process.key
                  manager.expanded.incl process.key
                invalidate()
            else:
              container(row(width = fixedPx(24), height = grow())): discard
            tableText(display(process.name), muted = entry.context)
          TableCell(rowId, 1, Columns[1]): tableText($process.key.pid)
          TableCell(rowId, 2, Columns[2]): tableText(if process.owner < 0: "—" else: $process.owner)
          TableCell(rowId, 3, Columns[3]): tableText($process.state)
          TableCell(rowId, 4, Columns[4]): tableText(formatFloat(process.cpu, ffDecimal, 1))
          TableCell(rowId, 5, Columns[5]):
            tableText(formatFloat(float(process.residentKiB) / 1024, ffDecimal, 1))
          TableCell(rowId, 6, Columns[6]):
            let protected = process.key.pid <= 1 or process.key.pid == int(getpid())
            let actions = if protected: @ActionOptions[0..1]
              elif process.owner != int(getuid()): @ActionOptions[0..5]
              else: @ActionOptions
            let action = comboBox(elementId("actions." & key), actions, 0,
              width = grow(), height = fixedPx(26))
            if action > 0:
              manager.target = process
              manager.action = action
              manager.notice = ""
              invalidate()
      if visible.last < rows.len:
        container(col(width = grow(), height = fixedPx(float32(rows.len - visible.last) * RowHeight))): discard

widget ManagerView():
  let id = hashId("processes")
  let previous = (manager.query, manager.owner, manager.state)
  container(col(width = grow(), height = grow(), padding = padAll(8), gap = 8).chrome(panel)):
    container(row(width = grow(), alignY = centerY, gap = 6)):
      manager.query = textField(hashId("search"), manager.query, "Search process, PID, or command",
        width = grow(175), tabIndex = 1)
      manager.owner = comboBox(hashId("owner"), @OwnerOptions, manager.owner, width = fixedPx(130))
      manager.state = comboBox(hashId("state"), @StateOptions, manager.state, width = fixedPx(120))
      if desktopButton(hashId("expand-all"), "Expand all"):
        manager.expandDefault = true
        manager.collapsed.clear()
        invalidate()
      if desktopButton(hashId("collapse-all"), "Collapse all"):
        manager.expandDefault = false
        manager.expanded.clear()
        manager.collapsed.clear()
        for process in manager.processes.values: manager.collapsed.incl process.key
        invalidate()
      if desktopButton(hashId("close"), "Close"): platform.quit()
    let filtersChanged = previous != (manager.query, manager.owner, manager.state)
    if filtersChanged: manager.collapsed.clear()
    if manager.action != 0: ActionPanel()
    if manager.notice.len > 0: text(manager.notice)
    ProcessTable(id, tree(), filtersChanged)

proc prepare() =
  installChrome()
  manager.sort = TableSort(column: 1)
  manager.sampled = getMonoTime()
  refresh()
  let init = manager.processes.getOrDefault(1)
  if init.name == "systemd":
    manager.expanded.incl init.key
  setFocus(hashId("search"))

proc view() =
  if pressed("Escape"):
    if manager.action != 0: manager.action = 0
    else: platform.quit()
  applyDesktopTheme(darkMode())
  if (getMonoTime() - manager.sampled).inMilliseconds >= 1000: refresh()
  requestFrameIn(1000)
  ManagerViewImpl()

when isMainModule:
  var layer: LayerConfig
  let args = commandLineParams()
  const Width = 870
  const Height = 520
  var width = Width
  if args.len == 5 and args[0] == "--attach":
    let outputWidth = max(1, parseInt(args[4]))
    width = min(Width, outputWidth)
    let inset = max(0, parseInt(args[3]))
    let requested = if args[2] == "left": outputWidth - inset - width else: inset
    let rightMargin = clamp(requested, 0, outputWidth - width)
    layer = LayerConfig(enabled: true, edge: edgeTop, level: layerOverlay,
      thickness: Height, length: int32(width), exclusive: 0, anchorEnd: true,
      marginEnd: int32(rightMargin), output: args[1],
      keyboard: keyboardOnDemand, namespace: "alatar-processui")
  run App(window: WindowConfig(title: "Process Manager", width: width.int32, height: Height,
    resizable: not layer.enabled, transparent: true, layer: layer),
    setup: prepare, view: view)
