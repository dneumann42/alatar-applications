import std/sequtils
import ellipse_ui
import ./[classicTheme, recipes, timerValues, unitEditor]

type
  WizardPage* = enum
    recipeCatalog, recipeIdentity, recipeSettings, recipeReview, recipeComplete

  RecipeWizardState* = object
    catalog*: RecipeCatalog
    page*: WizardPage
    draft*: RecipeDraft
    output*: seq[GeneratedUnit]
    preferredSystem: bool
    preview: int
    error: string
    generation: uint32

proc moveTo(state: var RecipeWizardState, page: WizardPage) =
  state.page = page
  state.error = ""
  inc state.generation
  invalidate()

proc openRecipeWizard*(state: var RecipeWizardState, defaultSystem: bool) =
  let generation = state.generation
  state = RecipeWizardState(generation: generation, preferredSystem: defaultSystem)
  state.catalog = loadRecipes()
  state.moveTo(recipeCatalog)

widget RecipeInputField(id: ElementId, field: RecipeInput, value: RecipeValue,
    order: int) -> RecipeValue:
  let theme = activeTheme
  if value.valueKind() != rvToggle:
    text(field.label, theme.text.caption)
  case value
  of TextValue(value):
    result = TextValue(text: textField(id, value, field.hint, tabIndex = order))
  of CommandValue(command):
    result = CommandValue(command: textField(id, command, field.hint, tabIndex = order))
  of PathValue(path):
    result = PathValue(path: textField(id, path, field.hint, tabIndex = order))
  of DurationSetting(duration):
    result = DurationSetting(duration: durationPicker(id, duration, order))
  of CalendarSetting(schedule):
    result = CalendarSetting(schedule: calendarPicker(id, schedule, order))
  of ToggleSetting(enabled):
    result = ToggleSetting(enabled: checkbox(id, field.label, enabled, tabIndex = order))

widget RecipeWizard(state: var RecipeWizardState) -> bool:
  ## Returns true when the user closes the wizard.
  result = false
  let theme = activeTheme
  let page = state.page
  let id = localId("recipe-page", state.generation)
  let bodyId = localId("recipe-wizard-body", id.id)
  let title = case page
    of recipeCatalog: "Choose a recipe"
    of recipeComplete: "Units created"
    else: state.draft.recipe.title

  classicTitle(title)
  case page
  of recipeCatalog:
    text("Start with a template that creates and connects the systemd units for you.",
      theme.text.control, theme.palette.dimColor)
    text("Custom recipes: " & recipeDirectory(), theme.text.caption, theme.palette.dimColor)
  of recipeIdentity, recipeSettings, recipeReview:
    let step = case page
      of recipeIdentity: "1 of 3  /  Name and scope"
      of recipeSettings: "2 of 3  /  Settings"
      else: "3 of 3  /  Review"
    text(step, theme.text.caption, theme.palette.accent)
  of recipeComplete:
    text("Reload the " & (if state.draft.system: "system" else: "user") &
      " systemd manager before enabling or starting the new units.",
      theme.text.control, theme.palette.dimColor)

  item(bodyId, col(width = grow(), height = grow(), gap = 12,
      padding = Padding(left: 14, right: 26, top: 12, bottom: 12))
      .bg(theme.palette.panelBg).corner(theme.radii.panel)
      .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
    case page
    of recipeCatalog:
      for first in countup(0, state.catalog.recipes.high, 2):
        container(row(width = grow(), gap = 16)):
          for index in first .. min(first + 1, state.catalog.recipes.high):
            let recipe = state.catalog.recipes[index]
            container(col(width = pct(0.49), gap = 5, padding = padAll(8))):
              if desktopButton(localIdWithIndex("choose-recipe", index.uint32, id.id), recipe.title,
                  fontSize = theme.text.control, width = grow(), tabIndex = index + 1):
                state.draft = newRecipeDraft(recipe, state.preferredSystem)
                state.moveTo(recipeIdentity)
              text(recipe.description, theme.text.caption, theme.palette.dimColor)
          if first == state.catalog.recipes.high:
            spacer()
      if state.catalog.errors.len > 0:
        text("Some custom recipes could not be loaded.")
        for error in state.catalog.errors:
          text(error, theme.text.caption, theme.palette.dimColor)
    of recipeIdentity:
      text(state.draft.recipe.description)
      container(col(width = grow(), gap = 4)):
        text("Unit name", theme.text.caption)
        state.draft.name = textField(localId("recipe-name", id.id), state.draft.name,
          "my-job", tabIndex = 1)
      container(col(width = grow(), gap = 4)):
        text("Description (optional)", theme.text.caption)
        state.draft.description = textField(localId("recipe-description", id.id),
          state.draft.description, "A short description of this job", tabIndex = 2)
      if state.draft.recipe.systemOnly:
        text("This recipe creates system units.", theme.text.caption)
      else:
        container(col(width = grow(), gap = 4)):
          text("Scope", theme.text.caption)
          state.draft.system = comboBox(localId("recipe-scope", id.id),
            @["User units", "System units"], ord(state.draft.system),
            width = fixedPx(180), tabIndex = 3) == 1
          state.preferredSystem = state.draft.system
      text("Save to " & UnitDraft(system: state.draft.system).unitDestination(),
        theme.text.caption, theme.palette.dimColor)
    of recipeSettings:
      if state.draft.recipe.inputs.len == 0:
        text("This recipe has no additional settings.")
      for index, field in state.draft.recipe.inputs:
        container(col(width = grow(), gap = 5)):
          state.draft.values[index] = RecipeInputField(
            localIdWithIndex("recipe-input", index.uint32, id.id), field,
            state.draft.values[index], index + 1)
    of recipeReview:
      let files = state.output.mapIt(it.name)
      state.preview = comboBox(localId("recipe-preview-choice", id.id),
        files, state.preview, tabIndex = 1)
      discard editor(localIdWithIndex("recipe-preview", state.preview.uint32, id.id),
        state.output[state.preview].content, EditorOpts(readOnly: true, wrap: false))
    of recipeComplete:
      for unit in state.output:
        text(unit.name)
      if state.draft.recipe.activation.len > 0:
        text(state.draft.recipe.activation, theme.text.control, theme.palette.dimColor)
    if page != recipeReview:
      scrollbar(localId("recipe-scrollbar", id.id), bodyId)

  if state.error.len > 0:
    let errorId = localId("recipe-error", id.id)
    item(errorId, col(width = grow(), height = fit(max = 108), padding = padAll(10))
        .bg(theme.palette.fieldBg).border(1, theme.palette.panelBorder)
        .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
      text(state.error)
      scrollbar(localId("recipe-error-scroll", id.id), errorId)

  container(row(width = grow(), gap = 8, alignY = centerY)):
    if page notin {recipeCatalog, recipeComplete}:
      if desktopButton(localId("recipe-back", id.id), "Back", fontSize = theme.text.control):
        state.moveTo(WizardPage(ord(page) - 1))
    spacer()
    if page in {recipeCatalog, recipeComplete}:
      result = desktopButton(localId("recipe-close", id.id), "Close", fontSize = theme.text.control)
    else:
      result = desktopButton(localId("recipe-cancel", id.id), "Cancel", fontSize = theme.text.control)
      let action = case page
        of recipeIdentity: "Continue"
        of recipeSettings: "Review units"
        else: "Validate and create"
      if desktopButton(localId("recipe-next", id.id), action, fontSize = theme.text.control):
        try:
          case page
          of recipeIdentity:
            discard recipeStem(state.draft.name)
            state.moveTo(recipeSettings)
          of recipeSettings:
            state.output = renderRecipe(state.draft)
            state.preview = 0
            state.moveTo(recipeReview)
          of recipeReview:
            saveRecipeUnits(state.output, state.draft.system)
            state.moveTo(recipeComplete)
          else:
            discard
        except CatchableError as error:
          state.error = error.msg
          invalidate()
