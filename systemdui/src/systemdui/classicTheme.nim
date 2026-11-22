## Live Alatar appearance for SystemDUI.
import ellipse_ui
import alatar/desktoptheme
import ./classicChrome

export classicChrome

var
  darkMode {.threadvar.}: bool
  switchMode {.threadvar.}: bool

proc useClassicTheme*() =
  installChrome()

proc applyClassicAppearance*(dark: bool) =
  darkMode = dark
  applyDesktopTheme(dark)

proc applyThemeToggle*() =
  if switchMode:
    switchMode = false
    try:
      setDesktopDarkMode(not systemDarkMode())
    except CatchableError as err:
      stderr.writeLine("systemdui: " & err.msg)
  applyClassicAppearance(systemDarkMode())

proc classicTitle*(title: string) =
  container(row(width = grow(), padding = Padding(left: 8, right: 4, top: 3, bottom: 3),
      gap = 8, alignY = centerY).chrome(panel)):
    text(title, activeTheme.text.control, activeTheme.palette.textColor)
    spacer()
    if desktopButton(hashId("appearance-mode"), (if darkMode: "Light mode" else: "Dark mode"),
        width = fixedPx(105), height = fixedPx(26)):
      switchMode = true
      invalidate()

template classicFrame*(frameHeight: SizingAxis, inset: bool, body: untyped) =
  let face = activeTheme.palette.buttonBg
  let highlight = lerp(face, rgb(255, 255, 255), 0.45)
  let shadow = lerp(face, rgb(0, 0, 0), 0.75)
  let topLeft = if inset: shadow else: highlight
  let bottomRight = if inset: highlight else: shadow
  var frame = col(width = grow(), height = frameHeight, padding = padAll(1)).bg(bottomRight)
  frame.border = BorderConfig(color: topLeft, width: BorderWidth(top: 1, left: 1))
  container(frame):
    body
