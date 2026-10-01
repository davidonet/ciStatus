# ciStatus

A macOS menu bar app that shows the state of your CI in one coloured dot.

It polls three kinds of source and rolls them up into a single indicator:

| Source | What it reports |
| --- | --- |
| GitHub | the CI state of a branch's head commit, via the Checks API or the Actions API (see [GitHub permissions](#github-permissions)) |
| Vercel | the state of the latest deployment for a project and branch |
| Sentry | issues first seen within a rolling window |

The dot reflects the worst source, never an average:

- **green** — everything passed
- **orange** — something is still running
- **red** — something failed
- **grey** — a source could not be reached, or is misconfigured

Grey deliberately ranks *below* red, so an unreachable API can never hide a
failure that was detected. A branch with no checks yet is green, not grey.

## Requirements

macOS 13 or later. Nothing to install beyond the build.

## Build and install

```sh
make            # build release, install to /Applications
make build      # build/CIStatus.app only
make test       # unit tests
```

`make build` produces `build/CIStatus.app`. Note that `swift build -c release`
on its own gives you a bare executable, not an app: with no `Info.plist` there
is no `LSUIElement`, so it shows up in the Dock and adds a second icon to the
menu bar. `Scripts/build-app.sh` does the bundling, and `make` calls it.

### Running it

Tokens are read from the environment, so the app has to be launched from a
terminal — neither Finder nor Spotlight forwards one:

```sh
GITHUB_API_KEY=… VERCEL_API_KEY=… SENTRY_API_KEY=… make run
```

For something that just works at login, register a LaunchAgent that holds the
tokens. It prompts for each one, writes them to
`~/Library/Application Support/CIStatus/secrets.env` with mode 600, and starts
the app on login:

```sh
./Scripts/install-launch-agent.sh
```

To undo it, including deleting the stored tokens: `./Scripts/uninstall-launch-agent.sh`.

Because that file is plaintext, rotate the tokens if the machine or backup is
ever exposed.

## Configuration

Config lives at `~/Library/Application Support/CIStatus/config.json`. Set
`CISTATUS_CONFIG` to point somewhere else. A commented example ships in
`Sources/CIStatus/Resources/config.example.json`:

```json
{
  "pollIntervalSeconds": 60,
  "sources": [
    {
      "kind": "github",
      "name": "api · main",
      "owner": "your-org", "repo": "api", "branch": "main",
      "strategy": "auto",
      "tokenEnv": "GITHUB_TOKEN"
    },
    {
      "kind": "vercel",
      "name": "web · production",
      "projectId": "prj_…", "teamId": "team_…", "branch": "main",
      "tokenEnv": "VERCEL_TOKEN"
    },
    {
      "kind": "sentry",
      "name": "Sentry · web",
      "org": "your-org", "project": "web",
      "newWithinHours": 24,
      "tokenEnv": "SENTRY_TOKEN"
    }
  ]
}
```

`name` is the label shown in the menu, so give it the thing you would say out
loud. Tokens are never written to this file: each source names an environment
variable to read instead. `dashboardURL` overrides the link a row opens, which
is handy when your dashboards live somewhere non-obvious.

The menu lists each source with its state, a count of what needs attention, and
the time of the last check. Clicking a row opens its dashboard. Edit the file
then use **Reload config** in the menu; there is no need to restart.

The env var names in the example are `GITHUB_API_KEY`, `VERCEL_API_KEY`, and
`SENTRY_API_KEY`, which is what the launch agent installer expects.

### Tokens

Each needs read scope only:

- Vercel: a token with access to the team owning the project
- Sentry: an auth token scoped to the project
- GitHub: see below

### GitHub permissions

There are two APIs that can answer "is CI green on this branch", and they need
different permissions. `strategy` picks between them:

| `strategy` | API | Token permission | Sees |
| --- | --- | --- | --- |
| `auto` *(default)* | Checks, falling back to Actions | `Checks: read`, else `Actions: read` | everything available |
| `checks` | Checks | `Checks: read` | Actions **and** third-party CI |
| `actions` | Actions | `Actions: read` | Actions only |

`auto` is the default because `Checks` is not offered for every GitHub account
or plan. If your token cannot read check runs, the app falls back to the
Actions API automatically and the menu row is marked `· actions only`.

The fallback is narrower, and it is worth knowing what you lose. The Actions
API only reports GitHub's own workflows, so checks posted by other apps are
invisible. On `nuxt/nuxt@main` for example, the Checks API reports 5
third-party checks (Socket Security, Flakiness, pkg-pr-new) that the Actions
API does not see at all. If you rely on any of those, grant `Checks: read` and
keep the default.

To resolve a branch to its head commit the fallback uses the combined status
endpoint, which needs `Commit statuses: read`. Together with `Actions: read`
that matches the permissions a fine-grained token offers as *"Read access to
actions, code quality, commit statuses, and metadata"*, so no extra
configuration is needed.

## Development

```sh
swift test                    # 48 unit tests, no network
make probe                    # poll your own config from the terminal
```

`probe` prints what the app would show, which is the fastest way to tell a bad
token from a bad config:

```sh
GITHUB_TOKEN=… .build/debug/probe ~/path/to/config.json
# ok      | api · main   | 12 passed                | your-org/api @ main
# failing | web · prod   | ERROR: Command failed    | target: production · sha: 0123abc
# unknown | Sentry · web | unreachable              | HTTP 404 …
```

`probe --overall <config>` prints just the rolled-up health, which is how the
end-to-end check derives what the dot should be.

### Verifying the icon

The dot is the product and it only exists on the real menu bar, so
`Scripts/e2e.sh` launches the built app, screenshots the bar, and classifies the
pixels the icon added by diffing against a baseline taken with the app not
running. It then compares that to the health the providers compute:

```sh
swift build -c release
swift build --product probe && swift build --product probe3
GITHUB_TOKEN=… ./Scripts/e2e.sh /path/to/config.json
# computed health: failing
# dot 14x14 at 3085,8 from 132 px rgb=240,177,76
# => RED
# PASS: icon is RED, matching the computed health
```

It needs a logged-in GUI session, and it reads the real screen, so treat a
failure as a prompt to look rather than a hard gate.

## Layout

```
Sources/CIStatusKit/    all the logic, so it is testable without an app bundle
  Health.swift          severity enum and the roll-up
  Config.swift          the config schema
  HTTP.swift            small async JSON client
  GitHubProvider.swift
  VercelProvider.swift
  SentryProvider.swift
  Monitor.swift         the poll loop
  StatusDot.swift       draws the coloured dot
Sources/CIStatus/       the SwiftUI menu bar extra, nothing but presentation
Sources/probe/          terminal front end for the providers
Sources/probe3/         menu bar pixel classifier used by the e2e check
```

## Notes

- Menu bar icons are drawn as template images, which discard colour, so
  `StatusDot` bakes the tint into the pixels with `isTemplate = false`. A plain
  SF Symbol would render black no matter what colour you apply.
- The Actions fallback filters workflow runs by `head_sha`, not by `branch`.
  Filtering by branch alone returns every commit ever pushed to it, so a
  failure from last month would keep the dot red forever.
- Both GitHub APIs cap a page at 100. When there are more, the summary says how
  many were not shown and the row reads as *pending* rather than green, so a
  partial view is never mistaken for a clean one.
- Sentry's search syntax is sent as a single query string; the window is
  `firstSeen:-<hours>h`.
