import std/[streams, strutils, unittest]
import systemdfile
import ../src/systemdui/unitEditor

suite "systemd files":
  test "ordered sections and directives, including repeated keys and resets":
    let input = newStringStream(
      "\xEF\xBB\xBF[Unit]\r\n Description = Café # literal; text \r\n" &
      "[Service]\r\nExecStart=/bin/true\r\nExecStart=\r\n" &
      "ExecStart=/bin/echo \"a=b\" 'c d' \\x21 %i\r\n" &
      "[Service]\r\n[Install]")
    let document = readSystemdFile(input)
    let output = newStringStream()
    output.writeSystemdFile(document)
    check output.data ==
      "[Unit]\nDescription=Café # literal; text\n" &
      "[Service]\nExecStart=/bin/true\nExecStart=\n" &
      "ExecStart=/bin/echo \"a=b\" 'c d' \\x21 %i\n" &
      "[Service]\n[Install]\n"
    case document.entries[5]
    of Directive(key, value):
      check key == "ExecStart"
      check value == "/bin/echo \"a=b\" 'c d' \\x21 %i"
    else:
      check false

  test "continuations skip full-line comments and respect escaped backslashes":
    let input = newStringStream(
      "# heading\n\n[Service]\nExecStart=/bin/echo \\\n" &
      "  # ignored\\\n\t; ignored\n  one\\\n  two\n" &
      "X-Test=literal\\\\\nX-Other=tail\\")
    let output = newStringStream()
    output.writeSystemdFile(input.readSystemdFile())
    check output.data ==
      "# heading\n\n[Service]\nExecStart=/bin/echo    one   two\n" &
      "X-Test=literal\\\\\nX-Other=tail\n"

  test "empty streams and streams positioned after a prefix":
    let output = newStringStream("prefix:")
    output.setPosition(7)
    output.writeSystemdFile(newStringStream().readSystemdFile())
    check output.data == "prefix:"
    let input = newStringStream("skip[Unit]")
    input.setPosition(4)
    output.writeSystemdFile(input.readSystemdFile())
    check output.data == "prefix:[Unit]\n"

  test "malformed input reports the starting physical line":
    for input in ["[Unit]\nbad\\\n line", "[Unit]\n[broken",
                  "[Unit]\n =value", "[Unit]\nKey=\xFF",
                  "[Unit]\nKey=before\0after"]:
      try:
        discard newStringStream(input).readSystemdFile()
        check false
      except SystemdSyntaxError as error:
        check error.line == 2

  test "writing validates entries before touching the stream":
    let output = newStringStream()
    let document = SystemdFile(entries: @[
      Section(name: "Unit"),
      Directive(key: "Bad=Key", value: "value")
    ])
    expect SystemdSyntaxError:
      output.writeSystemdFile(document)
    check output.data == ""

  test "read and write propagate stream I/O failures":
    let input = Stream()
    input.readDataImpl = proc (stream: Stream, buffer: pointer, size: int): int =
      raise newException(IOError, "read failed")
    expect IOError:
      discard input.readSystemdFile()
    let output = Stream()
    output.writeDataImpl = proc (stream: Stream, buffer: pointer, size: int) =
      raise newException(IOError, "write failed")
    expect IOError:
      output.writeSystemdFile(SystemdFile(entries: @[Section(name: "Unit")]))

  test "reads CR line endings across buffer boundaries":
    let input = newStringStream("#" & repeat(' ', 8190) & "\r\n[Unit]\rX-Test=yes")
    let output = newStringStream()
    output.writeSystemdFile(input.readSystemdFile())
    check output.data == "#" & repeat(' ', 8190) & "\n[Unit]\nX-Test=yes\n"

  test "preserves a literal trailing backslash during a round trip":
    let document = SystemdFile(entries: @[
      Directive(key: "X-First", value: "tail\\"),
      Directive(key: "X-Second", value: "next")
    ])
    let output = newStringStream()
    output.writeSystemdFile(document)
    output.setPosition(0)
    let parsed = output.readSystemdFile()
    check parsed.entries.len == 2
    case parsed.entries[0]
    of Directive(_, value):
      check value == "tail\\"
    else:
      check false

  test "rejects empty section names and embedded line breaks in model fields":
    expect SystemdSyntaxError:
      discard newStringStream("[]").readSystemdFile()
    for entry in [Directive(key: "Name\n", value: "value"),
                  Directive(key: "Name", value: "\nvalue")]:
      expect SystemdSyntaxError:
        newStringStream().writeSystemdFile(SystemdFile(entries: @[entry]))

  test "guided editing preserves other bytes and repeated directives":
    var draft = UnitDraft(kind: Service, content:
      "\xEF\xBB\xBF# Header\r\n[Unit]\r\n  Description = Old\r\n" &
      "[Service]\r\nExecStart=/bin/echo \\\r\n   unchanged\r\n" &
      "ExecStart=\r\nExecStart=/bin/true\r\n# Tail")
    draft.loadFields()
    check draft.formContent() == draft.content
    for setting in draft.fields.mitems:
      if setting.key == "Description":
        setting.value = "New"
      if setting.key == "ExecStart":
        check setting.occurrences == 3
    check draft.formContent() == draft.content.replace("  Description = Old", "Description=New")
