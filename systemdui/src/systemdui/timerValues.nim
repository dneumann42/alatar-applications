import std/[options, strutils, times]
import ellipse_ui/widgets/datetimepickers
export datetimepickers

const Weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

func durationText*(value: DurationValue): string =
  $value.amount & ["s", "min", "h", "d"][ord(value.unit)]

func simpleDuration*(text: string): Option[DurationValue] =
  let expression = text.strip().toLowerAscii()
  var endOfNumber = 0
  while endOfNumber < expression.len and expression[endOfNumber] in Digits:
    inc endOfNumber
  if endOfNumber notin 1..5:
    return
  let amount = parseInt(expression[0 ..< endOfNumber])
  if amount == 0:
    return
  let unit = case expression[endOfNumber .. ^1].strip()
    of "", "s", "sec", "second", "seconds": DurationUnit.seconds
    of "m", "min", "minute", "minutes": DurationUnit.minutes
    of "h", "hr", "hour", "hours": DurationUnit.hours
    of "d", "day", "days": DurationUnit.days
    else: return
  some(DurationValue(amount: amount, unit: unit))

func calendarText*(schedule: CalendarSchedule): string =
  let date = case schedule.pattern
    of Daily(): "*-*-*"
    of BusinessDays(): "Mon..Fri *-*-*"
    of Weekly(day): Weekdays[ord(day)] & " *-*-*"
    of SpecificDate(date): $date.year & "-" & twoDigits(ord(date.month)) &
      "-" & twoDigits(date.day)
  date & " " & twoDigits(schedule.time.hour) & ":" & twoDigits(schedule.time.minute) & ":00"

func simpleCalendar*(text: string): Option[CalendarSchedule] =
  let expression = text.strip()
  var schedule = CalendarSchedule()
  case expression
  of "daily", "midnight":
    return some(schedule)
  of "weekly":
    schedule.pattern = Weekly(weekday: dMon)
    return some(schedule)
  else:
    discard
  var parts = expression.splitWhitespace()
  if parts.len == 1:
    parts.insert("*-*-*", 0)
  elif parts.len == 2 and
      (parts[0] == "Mon..Fri" or parts[0] in Weekdays):
    parts.insert("*-*-*", 1)
  if parts.len notin 2..3:
    return
  let clock = parts[^1].split(':')
  if clock.len notin 2..3 or (clock.len == 3 and clock[2] != "00"):
    return
  try:
    let hour = parseInt(clock[0])
    let minute = parseInt(clock[1])
    if hour notin 0..23 or minute notin 0..59:
      return
    schedule.time = TimeOfDay(hour: hour, minute: minute)
    if parts[^2] == "*-*-*":
      if parts.len == 3:
        if parts[0] == "Mon..Fri":
          schedule.pattern = BusinessDays()
        else:
          let day = Weekdays.find(parts[0])
          if day < 0:
            return
          schedule.pattern = Weekly(weekday: WeekDay(day))
    elif parts.len == 2:
      let date = parts[0].split('-')
      if date.len != 3:
        return
      let year = parseInt(date[0])
      let month = parseInt(date[1])
      let day = parseInt(date[2])
      if year notin 1970..9999 or month notin 1..12 or
          day notin 1..getDaysInMonth(Month(month), year):
        return
      schedule.pattern = SpecificDate(date: CalendarDate(year: year, month: Month(month), day: day))
    else:
      return
    result = some(schedule)
  except ValueError:
    discard

func timerDurationKey*(key: string): bool =
  key in ["OnActiveSec", "OnBootSec", "OnStartupSec", "OnUnitActiveSec",
    "OnUnitInactiveSec", "AccuracySec", "RandomizedDelaySec"]
