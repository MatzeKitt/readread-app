# ReadRead

A reader for **FreshRSS** and **Mastodon** on iOS and macOS. One timeline, one set of keyboard
shortcuts, and a reading position that follows you between devices over a sync service you host
yourself.

Not shipped as a product; this is a personal app kept in a state where someone else could build it.

## What it does

- **Two sources, one timeline.** FreshRSS over the Google Reader API and Mastodon over its REST
  API, ingested into a single local store and read through the same three-column shell — sidebar,
  timeline, detail — on the Mac, iPad and iPhone.
- **Positions, not read flags.** A position is the item at the *fold*, per scope and per device.
  The count beside a feed is how many items sit above it, so scrolling up lowers it again. Each
  device writes only its own row, which is why position sync cannot conflict.
- **Read Later** with a snapshot, so a saved item survives the source dropping it.
- **Filter rules** — substring, whole-word or regular expression, over title, body, author or
  source — evaluated on ingest and re-evaluated when a rule changes.
- **Reader view** with the article extracted from the page, optional full-page loading per feed,
  and, for WordPress sites that advertise it, the post's comments.
- **Mastodon as a first-class timeline**: threads, polls, custom emoji, media viewer, like and
  boost.
- **Refreshes in the background** on iOS via `BGTaskScheduler`, with a badge that only publishes
  after a complete run.
- **Self-hosted sync** for positions, Read Later, filter rules and the account list. Credentials
  never leave the device's Keychain — see [server/README.md](server/README.md).

## Requirements

- macOS 26 or newer, and **Xcode 26 or newer** (the package needs the Swift 6.2 toolchain and the
  iOS 26 / macOS 26 SDKs)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A FreshRSS instance and/or a Mastodon account
- Optional: PHP 8.3 with `pdo_sqlite`, to run the sync service

## Building

**There is no `.xcodeproj` in the repository.** [project.yml](project.yml) is the source of truth
and the generated project is gitignored, so a fresh clone opened in Xcode shows a folder with
nothing to build. Generate it first:

```sh
make generate      # xcodegen generate
open ReadRead.xcodeproj
```

Re-run it whenever `project.yml` changes, or after adding a file outside the Swift package. Files
inside `Packages/ReadReadKit` are picked up automatically and need no regeneration.

From the command line:

```sh
make test          # package tests — no simulator needed, and the fastest loop
make build-mac     # build the macOS app
make build-ios     # build for the iOS Simulator (iPhone 17 Pro)
make run-mac       # build and launch on the Mac
make check         # everything CI would run
make clean         # remove build products and the generated project
```

`make help` lists the lot.

### Signing

The project is configured for **ad-hoc signing** (`CODE_SIGN_IDENTITY = "-"`), which is enough to
run locally on both platforms and still applies the sandbox and network entitlements. To run on a
physical iOS device or to distribute, set `DEVELOPMENT_TEAM` and switch `CODE_SIGN_STYLE` to
`Automatic` in [project.yml](project.yml), then regenerate.

### Debug fixtures

Launch with `-ReadReadFixtures` to seed an empty store with sample accounts and items — useful for
UI work without a live account. `-ReadReadFixtureItems 200` makes the timeline big enough for
scrolling to behave as it does on a real account.

## Layout

```
App/                      The app target: entry point, Info.plist, entitlements, assets
Packages/ReadReadKit/     Everything else, as a local Swift package
  ReadReadSupport/        HTTP client, HTML parsing and sanitising, article extraction, Keychain
  ReadReadModel/          SwiftData schema, positions, filters, Read Later, retention, ingest
  FreshRSSAPI/            Google Reader API client and ingest planner
  MastodonAPI/            Mastodon client, OAuth, ingest planner, backfill
  ReadReadSync/           Refresh engine and coordinator, sync client and outbox, background refresh
  ReadReadUI/             The SwiftUI layer
Design/AppIcon/           Icon artwork and the Icon Composer sources
server/                   The self-hosted sync service (PHP 8.3 + SQLite, no dependencies)
```

The layering runs one way: `ReadReadUI` → `ReadReadSync` → providers → `ReadReadModel` →
`ReadReadSupport`. Everything below the UI was built and tested without an app around it, and
[`AppServices`](Packages/ReadReadKit/Sources/ReadReadUI/AppServices.swift) is the single place that
starts it, so there is one answer to "what is running and why".

## Tests

Around 970 tests in Swift Testing, across every layer but the views:

```sh
make test
# or
swift test --package-path Packages/ReadReadKit
```

They need no simulator and no network — HTTP is faked through a stub transport and time through a
clock that does not sleep, both in `Tests/TestSupport`. Views themselves are verified by running
the app.

## The sync service

`server/` is about 700 lines of PHP over a SQLite file, with no `composer install`. It is a
revision-numbered blob store: it validates that a record is well-formed and small enough, then
stores the payload without looking inside, because every merge decision is made by the app. It
never receives a credential.

```sh
make server-dev     # php -S 127.0.0.1:8787
make server-test    # the smoke suite, against a throwaway database
```

Installation, the API and the token CLI are documented in [server/README.md](server/README.md).

## Localisation

English and German. The strings live in
[App/Resources/Localizable.xcstrings](App/Resources/Localizable.xcstrings) — in the *app* target
rather than beside the views, because SwiftUI resolves a `LocalizedStringKey` against
`Bundle.main`.
