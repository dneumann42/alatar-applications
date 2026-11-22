import std/[json, options, strutils, times, unittest]
import ../src/systemdui/[recipes, timerValues]

const RepeatDefinition = staticRead("../recipes/repeat-command.json")
const ProbeDefinition = staticRead("../recipes/calendar-command.json")

suite "recipes":
  test "repeating timer connects a oneshot service to a ten-second schedule":
    var draft = newRecipeDraft(parseRecipe(RepeatDefinition), false)
    draft.name = "check-job"
    draft.values[0] = CommandValue(command: "/usr/bin/true")
    let files = renderRecipe(draft)
    check files.len == 2
    check files[0].name == "check-job.service"
    check files[0].content.contains("Type=oneshot\nExecStart=/usr/bin/true")
    check not files[0].content.contains("WorkingDirectory=")
    check files[1].name == "check-job.timer"
    check files[1].content.contains("Unit=check-job.service")
    check files[1].content.contains("OnActiveSec=10s\nOnUnitActiveSec=10s")
    check files[1].content.contains("AccuracySec=1s")

  test "validates schema field references and rejects mismatched input types":
    var definition = parseJson(RepeatDefinition)
    definition["inputs"][2]["id"] = %"different"
    expect ValueError:
      discard parseRecipe($definition)
    definition = parseJson(RepeatDefinition)
    definition["inputs"][2]["type"] = %"toggle"
    definition["inputs"][2]["default"] = %true
    expect ValueError:
      discard parseRecipe($definition)

  test "rejects command line breaks and incorrect variant values":
    var draft = newRecipeDraft(parseRecipe(RepeatDefinition), false)
    draft.name = "check-job"
    draft.values[0] = TextValue(text: "/usr/bin/true")
    expect ValueError:
      discard renderRecipe(draft)
    draft.values[0] = CommandValue(command: "/usr/bin/true\nRestart=always")
    expect ValueError:
      discard renderRecipe(draft)

  test "specific calendar dates are validated and serialized":
    var definition = parseJson(ProbeDefinition)
    definition["inputs"][2]["default"] = %* {
      "frequency": "date", "year": 2028, "month": 2, "day": 29, "hour": 8, "minute": 30
    }
    let recipe = parseRecipe($definition)
    var draft = newRecipeDraft(recipe, false)
    draft.name = "calendar-check"
    draft.values[0] = CommandValue(command: "/usr/bin/true")
    let files = renderRecipe(draft)
    check files[1].content.contains("OnCalendar=2028-02-29 08:30:00")
    definition["inputs"][2]["default"]["year"] = %2027
    expect ValueError:
      discard parseRecipe($definition)

  test "timer picker conversions preserve supported expressions":
    check simpleDuration(" 30 minutes ").get().durationText() == "30min"
    check simpleDuration("1h 30min").isNone()
    let weekly = CalendarSchedule(pattern: Weekly(weekday: dSat),
      time: TimeOfDay(hour: 14, minute: 5))
    check simpleCalendar(weekly.calendarText()).get() == weekly
    check simpleCalendar("Mon..Fri 09:00").get().calendarText() == "Mon..Fri *-*-* 09:00:00"
    check simpleCalendar("09:00").get().calendarText() == "*-*-* 09:00:00"
    check simpleCalendar("*-*-* 12:30:00 UTC").isNone()
    check simpleCalendar("2027-02-29 09:00:00").isNone()
