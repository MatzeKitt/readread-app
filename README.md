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
  boost, profiles with their posts, followers and following — and **reply subscriptions**, which bring the replies to any post into the timeline and
  give each followed conversation a sidebar list of its own.
- **Refreshes in the background** on iOS via `BGTaskScheduler`, with a badge that only publishes
  after a complete run.
- **Self-hosted sync** for positions, Read Later, filter rules, reply subscriptions and the account
  list. Credentials never leave the device's Keychain — see [server/README.md](server/README.md).

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
run locally on both platforms and still applies the sandbox and network entitlements. The settings
live in [Config/Signing.xcconfig](Config/Signing.xcconfig), not in `project.yml`.

An ad-hoc Mac build asks for the login-keychain password after every rebuild, because the Keychain
knows it only by its code hash. To stop that, copy
[Config/Signing.local.xcconfig.example](Config/Signing.local.xcconfig.example) to
`Config/Signing.local.xcconfig` (gitignored), fill in your team and regenerate. The Mac build is
then signed with your development certificate, and access needs to be granted only once. The local
file survives `make generate`.

To run on a physical iOS device or to distribute, switch the target to `Automatic` signing with
your team in Xcode.

### Debug fixtures

Launch with `-ReadReadFixtures` to seed an empty store with sample accounts and items — useful for
UI work without a live account. `-ReadReadFixtureItems 200` makes the timeline big enough for
scrolling to behave as it does on a real account.

## Installing and updating on the Mac

Download `ReadRead-x.y.z.zip` from the [latest release](https://github.com/MatzeKitt/readread-app/releases/latest)
and move `ReadRead.app` to Applications. The app isn't notarized, so macOS blocks the first launch:
open it once, then go to System Settings → Privacy & Security and click "Open Anyway".

After that, ReadRead updates itself with [Sparkle](https://sparkle-project.org). It checks for
updates once a day, or whenever you choose ReadRead → Check for Updates…. Automatic installation
can be turned on in Settings → Updates. Debug builds never check, so a build from Xcode isn't
replaced by a downloaded release.

The app is sandboxed, so Sparkle installs through its bundled installer service. That needs
`SUEnableInstallerLauncherService` in `Info.plist` and the mach-lookup exceptions in
[ReadRead-macOS.entitlements](App/Resources/ReadRead-macOS.entitlements).

There are no iOS releases. The iOS app is still built and installed from Xcode.

## Releasing

Pushing a version tag builds, signs, and publishes a release of the Mac app:

```sh
git tag -a v1.2.3 -m "Release notes in Markdown"
git push origin v1.2.3
```

The [release workflow](.github/workflows/release.yml) uses the tag as the app version
(`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`), so tags must look like `v1.2.3`. The release
notes come from the tag message. A lightweight tag gets a list of commits since the previous tag
instead. The workflow publishes the zipped app together with `appcast.xml`, the Sparkle feed the
app reads from the latest release.

Updates are signed with an EdDSA key. The public key is `SUPublicEDKey` in
[project.yml](project.yml). The private key lives in the login keychain under the account
`readread` and in the `SPARKLE_PRIVATE_KEY` repository secret. To set the secret from the
keychain, run this after a build has resolved the Sparkle package:

```sh
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account readread -x sparkle-key.txt
gh secret set SPARKLE_PRIVATE_KEY < sparkle-key.txt
rm sparkle-key.txt
```

`DerivedData` is the project's folder under `~/Library/Developer/Xcode/DerivedData` for a build
from Xcode. Back up the private key. Without it, existing installations can't verify new updates.

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
