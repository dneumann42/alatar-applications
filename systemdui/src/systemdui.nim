import std/[cmdline, options, os, sequtils, strutils]
import ellipse_ui

import systemdui/[classicTheme, recipeWizard, systemdFile, systemdIO, timerValues, unitEditor]

const
  NewUnitMenu = "+ New service"
  ServiceColumns = [
    tableColumn("Unit", grow(230)),
    tableColumn("Type", fixedPx(100)),
    tableColumn("Scope", fixedPx(86)),
    tableColumn("Unit file", grow(295)),
    tableColumn("Actions", fixedPx(88), align = centerX, sortable = false)
  ]
  RowHeight = 42f
  ScopeOptions = @["User units", "System units", "All units"]
  UnitTypeLabels = ["Service", "Timer", "Socket", "Path watcher", "Target",
    "Mount", "Automount", "Swap", "Slice"]
  UnitTypeDescriptions = [
    "Run a program or manage a background process.",
    "Run another unit on a schedule.",
    "Listen on a socket and activate a service when traffic arrives.",
    "Activate another unit when a file or directory changes or appears.",
    "Group units so they can be started together.",
    "Mount a filesystem at an absolute path.",
    "Mount a filesystem on demand. Create a matching mount unit first.",
    "Configure a swap file or device.",
    "Group units and set resource limits."
  ]

type
  ServiceScope = enum
    userServices, systemServices, allServices

  Application = object
    services: seq[SystemdService]
    sort: TableSort
    query: string
    scope: ServiceScope
    unitTypeFilter: int
    draft: UnitDraft
    editing, sourceView, resetTableScroll: bool
    editorSession: uint32
    notice, error: string
    wizardOpen: bool
    wizard: RecipeWizardState

var application {.threadvar.}: Application

func kindIndex(kind: SystemdFileKind): int =
  EditableUnitKinds.find(kind)

func serviceField(service: SystemdService, column: int): string =
  case column
  of 0: service.name
  of 1: UnitTypeLabels[service.kind.kindIndex()]
  of 2: (if service.system: "System" else: "User")
  else: service.path

func filteredServices(services: seq[SystemdService], query: string,
                      scope: ServiceScope, typeFilter: int): seq[SystemdService] =
  let needle = query.strip().toLowerAscii()
  services.filterIt(
    (scope == allServices or it.system == (scope == systemServices)) and
    (typeFilter == 0 or it.kind.kindIndex() == typeFilter - 1) and
    (needle.len == 0 or needle in it.name.toLowerAscii() or
      needle in it.path.toLowerAscii() or needle in it.serviceField(1).toLowerAscii()))

proc openEditor(draft: sink UnitDraft) =
  application.editing = true
  application.draft = draft
  application.sourceView = false
  application.error = ""
  application.notice = ""
  inc application.editorSession
  editorClearHistory()
  try:
    application.draft.loadFields()
  except ValueError as error:
    application.sourceView = true
    application.error = "Correct the unit text to use the form. " & error.msg
  invalidate()

widget ServiceToolbar() -> bool:
  let previousQuery = application.query
  let previousScope = application.scope
  let previousType = application.unitTypeFilter
  let theme = activeTheme
  classicFrame(fit(), false):
    toolBar("unit-toolbar", proc() =
      container(row(width = grow(), gap = 8, alignY = centerY)):
        container(row(height = fixedPx(theme.metrics.controlHeight))
            .buttonChrome(elementId("menu." & NewUnitMenu))):
          menu(NewUnitMenu, proc() =
            for index, kind in EditableUnitKinds:
              if menuItem(UnitTypeLabels[index]):
                let system = application.scope == systemServices or
                  kind in {Mount, Automount, Swap}
                openEditor(newDraft(kind, system)))
        if desktopButton(hashId("open-recipe-wizard"), "Recipes", fontSize = theme.text.control,
            height = fixedPx(theme.metrics.controlHeight)):
          try:
            openRecipeWizard(application.wizard, application.scope == systemServices)
            application.wizardOpen = true
            application.error = ""
            invalidate()
          except CatchableError as error:
            application.error = error.msg
        application.query = textField(hashId("service-search"), application.query,
          "Search units by name, type, or path", tabIndex = 1)
        application.scope = ServiceScope(comboBox(hashId("service-scope"), ScopeOptions,
          ord(application.scope), width = fixedPx(152), tabIndex = 2))
        application.unitTypeFilter = comboBox(hashId("unit-type-filter"),
          @["All types"] & @UnitTypeLabels, application.unitTypeFilter,
          width = fixedPx(144), tabIndex = 3))
  result = application.query != previousQuery or application.scope != previousScope or
    application.unitTypeFilter != previousType

widget ServiceTable(id: ElementId, services: seq[SystemdService], sort: TableSort) -> TableSort:
  result = dataTable(id, ServiceColumns, services.len,
    cell = proc(index, column: int) =
      let unit = services[index]
      if column == ServiceColumns.high:
        if desktopButton(elementId("edit:" & $unit.system & ":" & unit.path), "Edit",
            width = fixedPx(64), height = fixedPx(30), fontSize = activeTheme.text.caption):
          try:
            openEditor(editDraft(unit))
          except CatchableError as error:
            application.error = error.msg
            invalidate()
      else:
        tableText(unit.serviceField(column), muted = column == 3),
    sort = sort,
    compare = proc(a, b, column: int): int =
      cmp(services[a].serviceField(column), services[b].serviceField(column)),
    rowKey = proc(index: int): string =
      services[index].path & ":" & $services[index].system,
    emptyText = "No units match your search and filters.",
    rowHeight = RowHeight).sort

proc refreshUnits() =
  try:
    application.services = listSystemdUnits()
  except CatchableError as error:
    application.error = "Could not load units. " & error.msg

widget ErrorPanel(message: string):
  let id = hashId("unit-error")
  let theme = activeTheme
  item(id, col(width = grow(), height = fit(max = 100), padding = padAll(10), gap = 4)
      .bg(theme.palette.fieldBg).border(1, theme.palette.panelBorder)
      .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
    text(message)
    scrollbar(localId("error-scroll", id.id), id)

widget TimerField(id: ElementId, setting: UnitField, tabOrder: int) -> string:
  result = setting.value
  let isCalendar = setting.key == "OnCalendar"
  let enabled = setting.value.len > 0
  let duration = if isCalendar: none(DurationValue) else: simpleDuration(setting.value)
  let calendar = if isCalendar: simpleCalendar(setting.value) else: none(CalendarSchedule)
  if enabled and duration.isNone() and calendar.isNone():
    text("Custom expression. Edit it in Unit file.", activeTheme.text.caption,
      activeTheme.palette.dimColor)
    text(setting.value, activeTheme.text.caption)
  elif checkbox(localId("timer-setting-enabled", id.id),
      (if isCalendar: "Set a calendar schedule" else: "Set a duration"), enabled,
      fontSize = activeTheme.text.caption, tabIndex = tabOrder):
    if isCalendar:
      let initial = calendar.get(CalendarSchedule(time: TimeOfDay(hour: 9)))
      let picked = calendarPicker(id, initial, tabOrder)
      if not enabled or picked != initial:
        result = picked.calendarText()
    else:
      let initial = duration.get(DurationValue(amount: 5, unit: DurationUnit.minutes))
      let picked = durationPicker(id, initial, tabOrder)
      if not enabled or picked != initial:
        result = picked.durationText()
  else:
    result = ""

widget DraftField(id: ElementId, setting: UnitField, tabOrder: int) -> string:
  result = setting.value
  container(col(width = grow(), gap = 3)):
    text(setting.label, activeTheme.text.caption)
    if setting.occurrences > 1:
      text("Multiple entries. Use Unit file to edit this setting.",
        activeTheme.text.caption, activeTheme.palette.dimColor)
    elif (setting.section == "Timer" and
        (setting.key == "OnCalendar" or setting.key.timerDurationKey())) or
        (setting.section == "Automount" and setting.key == "TimeoutIdleSec"):
      result = TimerField(id, setting, tabOrder)
    elif setting.section == "Service" and setting.key in ["Type", "Restart"]:
      var values = if setting.key == "Type":
        @["", "simple", "exec", "forking", "oneshot", "dbus", "notify", "notify-reload", "idle"]
      else:
        @["", "no", "on-success", "on-failure", "on-abnormal", "on-abort", "on-watchdog", "always"]
      if setting.value notin values:
        values.add setting.value
      var labels = values
      labels[0] = "Use systemd default"
      result = values[comboBox(id, labels, values.find(setting.value), tabIndex = tabOrder)]
    else:
      result = textField(id, setting.value, setting.hint, tabIndex = tabOrder)

proc switchEditorView() =
  try:
    if application.sourceView:
      application.draft.loadFields()
    else:
      application.draft.content = application.draft.formContent()
    application.sourceView = not application.sourceView
    application.error = ""
    inc application.editorSession
    editorClearHistory()
  except ValueError as error:
    application.error = error.msg
  invalidate()

proc saveEditor() =
  try:
    let content = if application.sourceView: application.draft.content
                  else: application.draft.formContent()
    let destination = saveUnit(application.draft, content)
    application.editing = false
    application.notice = "Saved " & destination.extractFilename() & ". Reload the " &
      (if application.draft.system: "system" else: "user") &
      " manager to apply it."
    application.query = ""
    if application.unitTypeFilter != 0:
      application.unitTypeFilter = application.draft.kind.kindIndex() + 1
    application.resetTableScroll = true
    if application.scope != allServices:
      application.scope = if application.draft.system: systemServices else: userServices
    application.error = ""
    refreshUnits()
  except CatchableError as error:
    application.error = error.msg
    if application.draft.system and ("Permission denied" in error.msg or
        "Read-only file system" in error.msg):
      application.error = "System units require write access to /etc/systemd/system.\n" &
        application.error
  invalidate()

widget UnitEditor():
  let kind = application.draft.kind
  let existing = application.draft.source.len > 0
  let theme = activeTheme
  let session = application.editorSession
  let formId = localId("unit-form", session)
  classicTitle((if existing: "Edit " else: "New ") & UnitTypeLabels[kind.kindIndex()])
  container(row(width = grow(), alignY = centerY, gap = 12)):
    text(UnitTypeDescriptions[kind.kindIndex()], theme.text.control, theme.palette.dimColor)
    spacer()
    if desktopButton(hashId("unit-editor-mode"), (if application.sourceView: "Guided form" else: "Unit file"),
        fontSize = theme.text.control):
      switchEditorView()
  container(row(width = grow(), gap = 12, alignY = centerY)):
    if existing:
      text(application.draft.name)
      text(if application.draft.system: "System unit" else: "User unit",
        theme.text.caption, theme.palette.dimColor)
    else:
      if kind in {Mount, Automount, Swap}:
        text("System unit · File name is derived from the absolute path.")
      else:
        application.draft.name = textField(hashId("unit-name"), application.draft.name,
          "Unit name (e.g. my-job." & $kind & ")", tabIndex = 1)
        let scope = comboBox(hashId("unit-save-scope"), @["User unit", "System unit"],
          ord(application.draft.system), width = fixedPx(160), tabIndex = 2)
        if application.draft.system != (scope == 1):
          application.draft.system = scope == 1
          # Keep the current form values while refreshing the scope-dependent hints.
          if not application.sourceView:
            try:
              application.draft.content = application.draft.formContent()
              application.draft.loadFields()
            except ValueError as error:
              application.error = error.msg
  text("Save to " & application.draft.unitDestination(), theme.text.caption, theme.palette.dimColor)
  if application.sourceView:
    application.draft.content = editor(localId("unit-file-editor", session),
      application.draft.content, EditorOpts(wrap: false)).text
  else:
    item(formId, col(width = grow(), height = grow(), gap = 12,
        padding = Padding(left: 12, top: 12, right: 24, bottom: 12))
        .bg(theme.palette.panelBg).corner(theme.radii.panel)
        .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
      for first in countup(0, application.draft.fields.high, 2):
        container(row(width = grow(), gap = 16)):
          for index in first .. min(first + 1, application.draft.fields.high):
            let setting = application.draft.fields[index]
            application.draft.fields[index].value =
              DraftField(localIdWithIndex("unit-field", index.uint32, session), setting, index + 3)
          if first == application.draft.fields.high:
            spacer()
      scrollbar(localId("unit-form-scroll", session), formId)
  if application.error.len > 0:
    ErrorPanel(application.error)
  container(row(width = grow(), gap = 8, alignY = centerY)):
    text("systemd checks the unit before saving.", theme.text.caption, theme.palette.dimColor)
    spacer()
    if desktopButton(hashId("cancel-unit"), "Cancel", fontSize = theme.text.control):
      application.editing = false
      application.error = ""
      invalidate()
    if desktopButton(hashId("save-unit"), (if existing: "Save changes" else: "Create unit"),
        fontSize = theme.text.control):
      saveEditor()

widget SystemDui():
  let tableId = hashId("services")
  container(col(width = grow(), height = grow(), padding = padAll(8), gap = 8).chrome(panel)):
    if application.wizardOpen:
      let before = application.wizard.page
      if RecipeWizard(application.wizard):
        application.wizardOpen = false
        invalidate()
      if before != recipeComplete and application.wizard.page == recipeComplete:
        application.notice = "Created " & $application.wizard.output.len & " unit files."
        application.query = ""
        application.unitTypeFilter = 0
        if application.scope != allServices:
          application.scope = if application.wizard.draft.system: systemServices else: userServices
        application.resetTableScroll = true
        refreshUnits()
    elif application.editing:
      UnitEditor()
    else:
      classicTitle("Services and units")
      let filtersChanged = ServiceToolbar()
      if application.notice.len > 0:
        text(application.notice)
      if application.error.len > 0:
        ErrorPanel(application.error)
      let services = filteredServices(application.services, application.query, application.scope,
        application.unitTypeFilter)
      classicFrame(grow(), true):
        application.sort = ServiceTable(tableId, services, application.sort)
      if filtersChanged or application.resetTableScroll:
        application.resetTableScroll = false
        setScrollPosition(tableBodyId(tableId), vec2(0, 0))
        invalidate()

when isMainModule:
  refreshUnits()
  application.sort = TableSort(column: 0)

  run App(window: WindowConfig(title: "SystemDUI", width: 980, height: 620, transparent: true),
          prepare: useClassicTheme,
          before: applyThemeToggle, view: SystemDuiImpl, hotApp: "--hot-app" in commandLineParams())
