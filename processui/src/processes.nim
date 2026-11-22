import std/[os, posix, strutils, tables]

type
  ProcessKey* = tuple[pid: int, started: uint64]
  Process* = object
    key*: ProcessKey
    parent*, owner*: int
    name*, command*: string
    state*: char
    residentKiB*, ticks*: uint64
    cpu*: float
  Snapshot* = Table[int, Process]

proc readStat(pid: int): Process =
  let stat = readFile("/proc/" & $pid & "/stat")
  let left = stat.find('(')
  let right = stat.rfind(')')
  if left < 0 or right <= left or right + 2 >= stat.len:
    raise newException(ValueError, "Invalid process stat")
  let fields = stat[right + 2 .. ^1].splitWhitespace()
  if fields.len < 22 or fields[0].len != 1:
    raise newException(ValueError, "Incomplete process stat")
  result = Process(key: (pid, parseBiggestUInt(fields[19])),
    name: stat[left + 1 ..< right], state: fields[0][0],
    parent: parseInt(fields[1]),
    ticks: parseBiggestUInt(fields[11]) + parseBiggestUInt(fields[12]),
    residentKiB: uint64(max(0, parseInt(fields[21]))) * uint64(sysconf(SC_PAGESIZE)) div 1024)

proc snapshot*(previous: Snapshot, seconds: float): Snapshot =
  let ticksPerSecond = float(sysconf(SC_CLK_TCK))
  for kind, path in walkDir("/proc"):
    if kind != pcDir: continue
    let name = path.lastPathPart
    if name.len == 0 or not name[0].isDigit: continue
    try:
      let pid = parseInt(name)
      var process = readStat(pid)
      process.owner = -1
      for line in lines(path / "status"):
        if line.startsWith("Uid:"):
          let fields = line.splitWhitespace()
          if fields.len >= 2: process.owner = parseInt(fields[1])
          break
      try:
        process.command = readFile(path / "cmdline").replace('\0', ' ').strip
      except IOError:
        discard
      if readStat(pid).key != process.key: continue
      let old = previous.getOrDefault(pid)
      if seconds > 0 and ticksPerSecond > 0 and old.key == process.key and process.ticks >= old.ticks:
        process.cpu = float(process.ticks - old.ticks) * 100 / (ticksPerSecond * seconds)
      result[pid] = process
    except IOError, OSError, ValueError:
      # Processes can disappear or become inaccessible during enumeration.
      discard

{.emit: """
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
static int processui_pidfd_open(int pid) {
  return (int)syscall(SYS_pidfd_open, pid, 0);
}
static int processui_pidfd_signal(int fd, int signal) {
  return (int)syscall(SYS_pidfd_send_signal, fd, signal, NULL, 0);
}
""".}
proc pidfdOpen(pid: cint): cint {.importc: "processui_pidfd_open", nodecl.}
proc pidfdSignal(fd, signal: cint): cint {.importc: "processui_pidfd_signal", nodecl.}

proc signalProcess*(process: Process, signal: cint) =
  if process.key.pid <= 1 or process.key.pid == int(getpid()):
    raise newException(ValueError, "This process is protected")
  let fd = pidfdOpen(cint(process.key.pid))
  if fd < 0: raiseOSError(osLastError())
  defer: discard close(fd)
  if readStat(process.key.pid).key != process.key:
    raise newException(ValueError, "Process identity changed")
  if pidfdSignal(fd, signal) < 0: raiseOSError(osLastError())
