import std/[osproc, paths, sequtils, sets, streams, strutils, sugar, os]
import systemdfile

type SystemdService* = object
  name*, path*: string
  system*: bool
  kind*: SystemdFileKind

proc readProcessLines*(cmd: string, args: openArray[string]): seq[string] =
  let process = startProcess(cmd, args = args, options = {poUsePath})
  let (lines, _) = process.readLines()
  process.close()
  result = lines

proc getSystemdFileDirs(): seq[tuple[path: Path, system: bool]] =
  let systemPaths = readProcessLines("systemd-analyze", ["unit-paths"])
  let userPaths = readProcessLines("systemd-analyze", ["--user", "unit-paths"])
  let tup = (sys: bool) => ((path: string) => (paths.Path(path), sys))
  result = systemPaths.map(tup(true)) & userPaths.map(tup(false))

type UnitFilePath = tuple[path: string, system: bool]

proc unitFilePaths(kinds: set[PathComponent]): seq[UnitFilePath] =
  getSystemdFileDirs()
    .map((directory) => walkDir(directory.path.string).toSeq
      .filterIt(it[0] in kinds)
      .mapIt(UnitFilePath((it[1], directory.system))))
    .foldl(a & b, newSeq[UnitFilePath]())

const EditableUnitKinds* = [Service, Timer, Socket, Path, Target, Mount,
  Automount, Swap, Slice]

func unitKind*(name: string): SystemdFileKind =
  let extension = name.splitFile().ext
  for kind in SystemdFileKind:
    if extension == "." & $kind:
      return kind
  raise newException(ValueError, "Unrecognized systemd unit type.")

proc listSystemdUnits*(): seq[SystemdService] =
  var seen: HashSet[tuple[name: string, system: bool]]
  # Keep the first unit in load-path order for each name and scope.
  for item in unitFilePaths({pcFile, pcLinkToFile}):
    let name = item.path.extractFilename()
    for kind in EditableUnitKinds:
      if name.endsWith("." & $kind) and not seen.containsOrIncl((name, item.system)):
        result.add SystemdService(name: name, path: item.path, system: item.system,
          kind: kind)
        break

proc listSystemdServices*(): seq[SystemdService] =
  listSystemdUnits().filterIt(it.kind == Service)

proc loadSystemdFile(path: string, system: bool): SystemdFile =
  let fstream = openFileStream(path, fmRead)
  defer: fstream.close()
  result = fstream.readSystemdFile()
  result.kind = SystemdFileKindRepr[path.splitFile()[2][1..^1]]
  result.path = path
  result.systemFile = system

proc readSystemdFiles*(): seq[SystemdFile] {.raises: [ValueError, IOError, OSError].} =
  unitFilePaths({pcFile})
    .filterIt(SystemdFileKindRepr.hasKey(it.path.splitFile()[2][1..^1]))
    .mapIt(loadSystemdFile(it.path, it.system))
