## SystemDUI controls rendered with the Alatar desktop chrome.
import ellipse_ui
import alatar/desktopchrome

export desktopchrome.installChrome, desktopchrome.chrome, desktopchrome.Chrome
from alatar/desktopchrome import desktopButton
export desktopButton

proc buttonChrome*(decl: sink ElementDeclaration, id: ElementId): ElementDeclaration =
  decl.chrome(desktopchrome.buttonChrome(id))
