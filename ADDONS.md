# Add-ons

**Add-on API, version 1.**

An add-on lets another app or tweak offer actions, conditions, banners and triggers in
RemoteCompanion without any change to RemoteCompanion. It is a single JSON file.

An add-on only **describes** what to do. It runs no code inside SpringBoard, so a mistake in one
can't crash it. Anything more involved belongs in the add-on's own tool or tweak, which the file
calls (`exec`, `notify`).

- [Install](#install)
- [Example](#example)
- [Rules that apply everywhere](#rules-that-apply-everywhere)
- [Add-on](#add-on) · [Actions](#actions) · [Options](#options) · [Input](#input) · [Steps](#steps)
- [Variables](#variables-and-templates) · [Banners](#banners) · [Conditions](#conditions)
- [Events and triggers](#events-and-triggers)
- [Running an action](#running-an-action) · [Commands](#commands) · [Limits](#limits)
- [Validation](#validation) · [Versioning](#versioning) · [Security](#security)

## Install

| | |
|---|---|
| Rootless | `/var/jb/Library/RemoteCompanion/AddOns/<id>.json` |
| Rootful | `/Library/RemoteCompanion/AddOns/<id>.json` |

A package ships its own file there. RemoteCompanion reads every `*.json` in both folders at start
and again within a couple of seconds of any change (also on `addons reload`), so installing or
removing an add-on needs no respring. Files are read in alphabetical order, the rootless folder
first; when two files use the same `id` the first one is used and the other is reported as a
problem.

The app (Settings > Integrations > Add-ons) lists what loaded, what isn't installed, and any file
with a problem and its reason.

## Example

A small file you can try without any other tweak is [`examples/hello.json`](examples/hello.json): copy it into the Add-ons folder and `hello greet goodbye` shows a toast.

A fuller one:

```json
{
  "api": 1,
  "id": "nightlight",
  "name": "Night Light",
  "requires": ["/Library/MobileSubstrate/DynamicLibraries/NightLight.dylib"],
  "actions": [
    {
      "command": "light",
      "name": "Night Light",
      "icon": "lightbulb.fill",
      "options": [
        { "id": "mode", "title": "Mode", "choices": [
          { "word": "toggle", "label": "Toggle", "value": "Toggle" },
          { "word": "on",     "label": "On",     "value": "On" },
          { "word": "off",    "label": "Off",    "value": "Off" } ] },
        { "id": "color", "title": "Color", "skipWhen": { "mode": "off" }, "choices": [
          { "word": "warm", "label": "Warm" },
          { "word": "cool", "label": "Cool" } ] },
        { "id": "brightness", "title": "Brightness", "skipWhen": { "mode": "off" }, "choices": [
          { "word": "low",  "label": "Low" },
          { "word": "high", "label": "High" } ] }
      ],
      "run": [
        { "defaults": { "domain": "com.example.nightlight", "key": "color", "value": "{color}" } },
        { "defaults": { "domain": "com.example.nightlight", "key": "brightness", "value": "{brightness}" } },
        { "notify": "com.example.nightlight/toggle", "if": { "var": "mode", "unset": true } },
        { "notify": "com.example.nightlight/toggle", "if": { "var": "mode", "is": "Toggle" } },
        { "notify": "com.example.nightlight/on",     "if": { "var": "mode", "is": "On" } },
        { "notify": "com.example.nightlight/off",    "if": { "var": "mode", "is": "Off" } }
      ],
      "banner": {
        "title": "Night Light", "icon": "lightbulb.fill",
        "await": "com.example.nightlight/state",
        "states": { "1": "On", "0": "Off" }
      }
    }
  ],
  "conditions": [
    { "id": "lit", "name": "Night Light On", "type": "choice",
      "notifyState": "com.example.nightlight/state", "choices": { "1": "Yes", "0": "No" } }
  ],
  "events": [
    { "notify": "com.example.nightlight/state",
      "trigger": { "id": "power", "name": "Night Light", "icon": "lightbulb.fill",
                   "states": { "1": "Turned On", "0": "Turned Off" } } }
  ]
}
```

`nightlight light on warm` runs the action with Mode = On and Color = Warm; `nightlight
light` runs it with nothing chosen, so it toggles and leaves the color and brightness as they are.

## Rules that apply everywhere

- **JSON.** One object. Unknown keys are ignored when loading (and listed as warnings by
  `addons validate`), so a newer add-on still loads on an older RemoteCompanion where it can.
  Exception: a step with an unknown key is a problem.
- **Strict kinds.** A key with the wrong kind of value (text where a number belongs, and so on)
  makes the whole file a problem. A file with a problem is left out, and the reason is shown.
- **Words.** `command` and a choice's `word` are lowercase; commands are matched without regard to
  case.
- **Icons** are SF Symbol names (`"mic.circle.fill"`). An unknown name shows no icon. The `icon` of an
  add-on, action, condition or trigger can instead name an image file (see Add-on); banners use
  symbols only.
- **Text** is shown as written; there's no markup.
- **Paths** in `requires` and `exec` are absolute. A path that doesn't start with `/var/` also
  gets `/var/jb` tried in front of it on rootless, for `requires` only; `exec` takes the path as
  given.

## Add-on

| Key | | Kind | Meaning |
|---|---|---|---|
| `api` | | whole number ≥ 1 | The API version the file is written for. Default 1. A file for a newer API than the app has is a problem ("needs add-on API N"). |
| `id` | required | text | The command word: lowercase letters, digits and `-`. `addons` is reserved. Built-in commands are checked first, so an id that is also a built-in command word is never reached. |
| `name` | required | text | Shown in the app and in banners. |
| `icon` | | text | The add-on's icon: an SF Symbol, **or an image file** (a name ending in `.png`, `.jpg` or `.jpeg`, found beside the JSON file, or an absolute path). It is also the icon of everything in the add-on that has no `icon` of its own: actions, conditions and triggers. An image is cut to a rounded square; give it a square picture of at least 120 px, under 512 KB. A missing or oversized image falls back to the puzzle piece (`addons validate` warns). Default: a puzzle piece. |
| `requires` | | list of paths | Offered only when at least one path exists; otherwise listed as not installed. Leave out to always offer it. |
| `actions` | required | list, not empty | See [Actions](#actions). |
| `conditions` | | list | See [Conditions](#conditions). |
| `events` | | list | See [Events and triggers](#events-and-triggers). |

## Actions

| Key | | Kind | Meaning |
|---|---|---|---|
| `command` | required | text | The words after the add-on's id, lowercase, one or more (`"light"`, `"limit set"`). Unique within the add-on. When commands share a start (`charge limit`, `charge limit level`), the **longest** one that fits the typed words runs. |
| `name` | required | text | The action's name. Listed as "Add-on: Name" in the action list and as "Name" inside the add-on's own list. |
| `icon` | | text | An SF Symbol or an image file, as for the add-on. Default: the add-on's icon. |
| `options` | | list | See [Options](#options). |
| `input` | | object | See [Input](#input). |
| `run` | required | list, not empty | See [Steps](#steps). |
| `banner` | | object | See [Banners](#banners). Each action with a banner gets its own switch in Settings > Banners. |

## Options

An option offers fixed choices. Picking the action opens its options, each starting on **Keep
Current** (no choice). A choice adds its `word` to the command.

```json
{ "id": "color", "title": "Color", "choices": [ { "word": "warm", "label": "Warm", "value": "Warm" } ],
  "skipWhen": { "other-option-id": "word" } }
```

| Key | | Meaning |
|---|---|---|
| `id` | required | Lowercase letters, digits and `_`, starting with a letter. Names the variable `{id}`. Unique within the action. Not `input`, `state` or `word1`, `word2`... |
| `title` | | Shown for the option. Default: the id. |
| `choices` | required, not empty | Each `{ "word", "label", "value" }`: `word` is one word of lowercase letters, digits, `-` and `.`, **unique across all of the action's options** (it's what identifies the choice in a command); `label` is shown (default: the word); `value` is what `{id}` becomes (default: the word). |
| `skipWhen` | | `{ "<other option id>": "<word>" }`: the option is left out (hidden, and ignored) while that other option has that choice. The other option must exist. |

When an action runs, each remaining word of the command that is a choice's word sets that
option's variable. An option never chosen has **no value**: any step that uses it is skipped (see
[Variables](#variables-and-templates)).

## Input

`"input": { "title": "Stop At (%)", "placeholder": "80", "number": true }`

Adds a text field. Whatever the user types is added to the command (after the option words) and
available as `{input}`. All three keys are optional: `number` only picks a number keyboard; it
doesn't check the value. Empty input leaves `{input}` unset.

## Steps

`run` is a list, run in order, one at a time. A step is an object with exactly **one kind** key,
plus the modifiers that kind allows.

| Kind | Value | Does |
|---|---|---|
| `notify` | text | Posts a Darwin notification of that name. Modifier `"state": <number>` sets the notification's state first (kept registered so it stays set). |
| `defaults` | object | Writes or reads a preference. See below. |
| `exec` | list of text | Runs a program **without a shell**: the first entry is the full path, the rest are its arguments (each filled as text). Run as mobile; modifier `"root": true` runs it as root through `rc-root`. PATH includes the jailbreak's tool folders. Its output (stdout and stderr) is added to the action's reply, **or**, with `"as": "name"`, kept in the variable `{name}` (its non-empty lines joined with ` · `) for later steps and the banner, and left out of the reply. Stopped after 10 s. |
| `url` | text | Opens a URL (`scheme://...`). |
| `command` | text | Runs a RemoteCompanion command. Add-on commands can run others, up to 4 deep. |
| `delay` | number | Waits that many seconds (clamped to 0-5). |

Modifiers on any step: `"if": { "var": "name", "is": "value" }`, `"isNot"`, or `"unset": true`
(runs only when the variable has, doesn't have, or has no value); `"ifOptions": true` (runs only
when at least one option was chosen). `state` is only for `notify`; `root` and `as` only for `exec`.

### `defaults`

`{ "domain", "key", "value", "type", "toggle", "read", "as", "labels" }`

- Writes `value` (text, filled from variables) to the preference. `type` is `"string"` (default),
  `"bool"` (`1`, `true`, `yes`, `on`) or `"int"`. A number or boolean given as JSON is written as
  it is when no `type` is set.
- `"toggle": true` flips a boolean preference instead of writing `value`.
- `"read": true` reads the preference into variable `as` (required); a boolean is read as its
  label.
- `as` on a toggle saves the new value in that variable. `labels` is `{ "true": "...",
  "false": "..." }` for the label of a boolean (default On and Off).
- Domain `com.apple.springboard` is SpringBoard's own preferences. Any other domain is written
  through the preferences system as mobile and synchronised.

## Variables and templates

Text in `notify`, `url`, `command`, `exec` and `defaults.value`, and in banner subtitles, can use
`{name}`.

| Variable | Set by |
|---|---|
| `{<option id>}` | An option's chosen choice: its `value`. |
| `{word1}`, `{word2}`... | The command's words that aren't choices, in order. |
| `{input}` | Those same words joined with spaces. |
| `{<as>}` | A `defaults` step with `as`, or an `exec` step with `as` (its output). |
| `{state}` | In an event or `await` banner: the text for the notification's state. |

**An unset variable skips the step** that uses it (that's how Keep Current leaves a setting
alone). In an action banner's subtitle it falls back to the action's name; in an event or
`await` banner it shows no banner. An unclosed `{` is kept as written. There is no escaping and
no nesting.

## Banners

A banner is a short pop-up after an action runs, or for an event.

```json
"banner": { "title": "Charging", "subtitle": "{state}", "icon": "bolt.fill", "hold": 2 }
"banner": { "await": "com.example/state", "states": { "1": "Recording", "0": "Not Recording" }, "timeout": 8 }
```

| Key | Meaning |
|---|---|
| `title` | Default: the add-on's name. In an action's banner that doesn't `await`, it is filled from variables like the subtitle (an unset one falls back to the add-on's name). |
| `subtitle` | Filled from variables. Default: the action's name; for a state banner, the state's text. |
| `icon` | An SF Symbol. Default: the action's icon. |
| `hold` | Seconds shown. Default 2. |
| `await` | A notification name (filled from variables). The banner waits for it and shows the text for its **state**, or **nothing** after `timeout`. It is armed before the steps run, so a quick reply isn't missed. |
| `states` | `{ "<state number>": "text" }`. For `await` and event banners. A state with no entry shows nothing. Without `states`, the number itself is shown. |
| `timeout` | Seconds to wait for `await`: 1-30, default 8. |

Whether an action's banner shows is the user's choice in Settings > Banners (on by default for
actions with a banner). An event tied to an action (`"action"`) shares that switch.

## Conditions

Conditions appear in If-actions and trigger conditions as "Add-on: Name".

```json
{ "id": "temperature", "name": "Battery Temperature", "type": "number",
  "exec": ["/var/jb/usr/bin/tool", "get", "temperature"], "root": false }
{ "id": "guard", "name": "Heat Guard", "type": "choice",
  "notifyState": "com.example/guard", "choices": { "0": "Normal", "1": "Hot" } }
```

| Key | | Meaning |
|---|---|---|
| `id`, `name` | required | The condition's id (unique in the add-on) and its name. |
| `icon` | | An SF Symbol or an image file, as for the add-on. Default: the add-on's icon. |
| `type` | required | `number` or `choice`. |
| `exec` | one of these | A program as in a step: the value is its trimmed output. A non-zero exit means the value is unknown and the condition is false. `"root": true` runs it as root. |
| `notifyState` | | A notification name; the value is its current state number. |
| `choices` | required for `choice` | `{ "<raw value>": "label" }`: the raw value (from `exec` or `notifyState`) maps to the label that the condition is compared with. |

`number` conditions are compared with "above" and "below" a number, as the built-in ones (battery
level and so on) are. `choice` conditions are equal or not equal to one of the labels
(case-insensitive). The condition's key is `addon:<id>:<condition id>`.

## Events and triggers

An event watches a Darwin notification that another tweak posts by itself.

```json
{ "notify": "com.example/limit", "action": "light",
  "banner": { "subtitle": "Stopped: {state}", "states": { "1": "Maximum Length" } },
  "trigger": { "id": "limit", "name": "Limit", "icon": "exclamationmark.circle", "states": false } }
```

| Key | | Meaning |
|---|---|---|
| `notify` | required | The notification name. |
| `banner` | one of these | Shown when it arrives. See [Banners](#banners) (`await` doesn't apply). |
| `trigger` | | Makes the event a trigger source. |
| `action` | | An action `command` of this add-on: the event's banner then shares that action's switch. |

A **trigger** is `{ "id", "name", "icon", "states" }` (`icon`: a symbol or an image file; default the add-on's icon). `id`: lowercase letters, digits, `-` and
`.`, unique in the add-on. When the notification arrives, RemoteCompanion runs the action lists
of these triggers, if the user has added them:

- the trigger itself: key `addon_<add-on id>_<trigger id>`, named "Add-on: Name";
- the trigger for the state that arrived: key `addon_<add-on id>_<trigger id>_<state number>`,
  named "Add-on: Name (state text)".

The state texts come from the trigger's `states` (`{ "1": "Started" }`), else from the banner's
`states`. `"states": false` offers only the first. Both run for each arrival. Triggers follow the
usual rules: the master switch, excluded apps, and so on.

## Running an action

1. The command is `<add-on id> <action words> [choice words] [input words]`.
2. Built-in commands are tried first; then the add-on with that id; then its longest matching
   action. No match returns the add-on's list of actions.
3. Choice words set option variables; the rest become `{word1}`... and `{input}`.
4. If the banner has `await`, it is armed.
5. The steps run in order (a step whose variables are unset, or whose `if` fails, is skipped).
6. A banner without `await` shows. The reply is the steps' `exec` and `command` output, or
   "Add-on: Action" when there is none.

Each action runs to the end; a failing step doesn't stop the ones after it. `exec` that can't
start adds an error line to the reply.

## Commands

- `addons`: lists the loaded add-ons, those not installed, and any problems.
- `addons reload`: reads the folders now.
- `addons validate <file>`: checks one file and prints `OK` with warnings, or the problem.
- `addons check addon:<id>:<condition> [expected]`: a condition's value, and whether it matches
  `expected` (for `number`, like `ABOVE 40`; for `choice`, a label).
- `GET /api/addons` (Web UI): the loaded add-ons as JSON, and the problems.

## Limits

| | |
|---|---|
| `exec` run time | 10 s, then stopped. Output kept: 64 KB. |
| `delay` | 5 s at most. |
| Command nesting | 4 deep. |
| `await` timeout | 1-30 s. |
| Choices/words | Lowercase letters, digits, `-` and `.`. |

## Validation

`addons validate <file>` applies the rules above. The same checks decide whether a file loads:
`api`, `id`, names and kinds, unique commands, option ids and choice words, `skipWhen` targets,
step shapes, banner kinds, condition kinds and choices, event and trigger shapes and the `action`
an event names. [`addon.schema.json`](addon.schema.json) describes the format for an editor
(point your editor's JSON schema setting at it); the schema can't check the cross-references,
`addons validate` can.

## Versioning

`api` is a whole number. Within one version, changes only **add**: new optional keys, new step
kinds that older builds report as problems only when used. Anything that changes the meaning of
existing keys is a new version. A file for a version the app doesn't know is not loaded, and the
reason says which one it needs.

## Security

An add-on is trusted the way an installed tweak is: its file sits in a folder only root can write.
It can run programs as mobile, or as root with `"root": true`, post notifications and write
preferences. There's no shell, no code in SpringBoard and no network access of its own. Anyone
who can send RemoteCompanion commands (the Web UI, MQTT, Home Assistant) can run an add-on's
actions, as they can any command.
