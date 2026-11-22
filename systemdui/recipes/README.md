# SystemDUI recipes

Open **Recipes** in SystemDUI to choose a recipe, name the units, fill in their settings, and preview every generated file. **Validate and create** checks all the files together with systemd before saving. The final screen lists the files and explains how to activate them.

## Add a recipe

Copy [repeat-command.json](repeat-command.json) or another built-in example to `${XDG_CONFIG_HOME:-$HOME/.config}/systemdui/recipes/`. Give it a descriptive filename ending in `.json` and edit its title, fields, and units. Reopen **Recipes** to load it. Errors in a custom file are shown with its filename.

A definition uses `"version": 1` and has a `title`, a `description`, an `inputs` array, and a `units` array. Optional `activation` text appears after creation. Set `systemOnly` to `true` to restrict the recipe to the system manager. Mount, automount, and swap recipes use the system manager automatically.

Each input has a unique `id`, a visible `label`, and a `type`. An optional `hint` appears in text fields.

| Input type | Example default | Control |
| --- | --- | --- |
| `text` | `"daily backup"` | Text field |
| `command` | `"/usr/bin/my-program --backup"` | Systemd command line |
| `path` | `"/var/lib/my-app"` | Absolute path field |
| `duration` | `{"amount": 10, "unit": "seconds"}` | Amount and units. Supports seconds, minutes, hours, and days. |
| `calendar` | `{"frequency": "weekdays", "hour": 9, "minute": 30}` | Recurrence, clock time, and date controls |
| `toggle` | `true` | Checkbox |

Calendar frequencies are `daily`, `weekdays`, `weekly`, and `date`. Weekly defaults also need a `weekday` from 1 (Monday) to 7 (Sunday). Specific dates need numeric `year`, `month`, and `day`. Text, command, and path inputs are required by default. Set `"required": false` to omit the directive when the field is left blank.

Each output unit specifies its file `type` and an ordered list of `directives`. A directive specifies its systemd `section`, `key`, and exactly one value source.

| Source | Example | Result |
| --- | --- | --- |
| Fixed text | `{"text": "oneshot"}` | Use the literal value |
| Input | `{"input": "interval"}` | Format a typed wizard value for systemd |
| Unit reference | `{"unit": "service"}` | Insert the generated service’s filename |
| Startup target | `{"startupTarget": true}` | Use `default.target` for user units or `multi-user.target` for system units |

A recipe can generate one file per unit type. The name entered in the wizard becomes the shared filename stem. Mount, automount, and swap names are derived from their path settings. Refer to a generated file with a unit reference so the recipe works with any supplied name.

Recipes support services, timers, sockets, path watchers, targets, mounts, automounts, swap units, and slices. Custom recipes use the same review and validation flow as built-in recipes. Unit files are saved only when you choose **Validate and create**.
