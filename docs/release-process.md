# Releasing Auster

One manually-triggered workflow does everything: build, sign, notarize, package,
publish, and update the Sparkle feed. Real releases run only from `main`, because
the appcast is served from `main`; dry runs can run from any branch.

## Releasing

1. **Write the notes as you go.** Every user-facing change adds a
   [Changie](https://changie.dev) fragment in its own PR: `changie new`, or
   `changie new --kind Fixed --body "…"`. Kinds are `New`, `Changed`, `Fixed` and
   `Updated`, written for users. See [`.changes/README.md`](../.changes/README.md)
   for what renders and what is refused.
2. **Dry run.** Actions → *🚀 Release* → *Run workflow*, on `main`, with
   **dry-run checked**. This builds, signs, notarizes and uploads the DMG as a
   workflow artifact, and touches nothing else — no tag, no release, no feed
   change. Download the artifact and check it opens on a machine that has never
   run Auster.
3. **Release.** Run it again with **dry-run unchecked**. The release type
   defaults to `auto`: a `New` fragment bumps the minor version, anything else
   the patch. `patch`, `minor` and `major` override it.

Changie batches the fragments into `.changes/<version>.md`, regenerates
`CHANGELOG.md`, and stamps the version into `Config/Shared.xcconfig`. fastlane
(`fastlane/Fastfile`) imports the certificate, archives, exports and notarizes.
The run then tags `v<version>`, creates the GitHub release with the DMG and the
notes, appends the signed entry to `.sparkle/appcast.xml`, and pushes all of
that to `main` as `chore: release <version> (<build>) [skip ci]`.

To run the lanes locally, install the gems outside the repository, because
`swift-format lint -r ./` would otherwise lint the fastlane gem's Swift files:
`BUNDLE_PATH=~/.cache/auster-gems bundle install`, then
`BUNDLE_PATH=~/.cache/auster-gems bundle exec fastlane build version:0.1.0 build:1`.

## Versions

- **Marketing version** (`MARKETING_VERSION`, `CFBundleShortVersionString`) lives
  in `Config/Shared.xcconfig`. Changie bumps it from the newest
  `.changes/<version>.md` and stamps it in. The first release ships as the
  version already in the xcconfig. It is what people see.
- **Build number** (`CURRENT_PROJECT_VERSION`, `CFBundleVersion`) is
  `git rev-list --count HEAD` — the commit count. Sparkle compares *this* to
  decide whether an update is newer, which is why the checkout uses
  `fetch-depth: 0`: a shallow clone counts 1, and a release numbered 1 would be
  offered to nobody, ever. It is passed to the build and not written back.

## What stops a bad release

All of it runs before the ~15-minute build:

| Guard | Why |
|---|---|
| Must run from `main` (except dry runs) | The feed is served from `main`; a release from a branch would strand its own appcast entry |
| Tag `v<version>` must not exist | Two releases claiming one version |
| Build number must exceed the newest appcast entry | Sparkle would never offer the update |
| There must be unreleased Changie fragments | A release with no notes |
| Notes must render | Malformed Markdown reaching the feed |
| A Developer ID identity must be present and unexpired | An unsignable build |
| `notarytool history` must accept the API key | An unnotarizable build |
| `SUPublicEDKey` must not be the placeholder | An app that can never accept an update |

And after the build: the exported app's version and build must match what was
resolved, `codesign --verify --deep --strict` must pass, and the signing
authority must be a Developer ID Application certificate — the archive may carry
a development signature, since only the export re-signs.

The publication steps come last and are skipped entirely on a dry run, so a
failed run leaves nothing behind. Just fix it and run again.

## Secrets

Repository settings → Secrets and variables → Actions.

| Secret | What it is | Expires |
|---|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate, exported from Keychain Access **with its private key** as `.p12`, then `base64 -i cert.p12 \| pbcopy` | Certificate: 5 years |
| `DEVELOPER_ID_CERT_PASSWORD` | The password set during that export | — |
| `AC_API_KEY_P8_BASE64` | App Store Connect API key (`.p8`), base64 encoded. App Store Connect → Users and Access → Integrations → keys, role *Developer* | No |
| `AC_API_KEY_ID` | Shown beside the key | No |
| `AC_API_ISSUER_ID` | Shown above the key list | No |
| `SPARKLE_ED_PRIVATE_KEY` | The EdDSA private key, printed by Sparkle's `generate_keys -x -` | No |
| `DROPBOX_APP_KEY` | The Dropbox app key. Not a cryptographic secret — OAuth uses PKCE (decisions D3) — but it is per-developer, so it stays out of the repository. The workflow writes it into `Config/Secrets.xcconfig` before the build; without it the released app quits at launch saying it has no key | No |

The team ID (`TCQ6328PP6`) is in `fastlane/Fastfile` and in the workflow's
`TEAM_ID`. It is not a secret.

### The Sparkle key pair

The private half signs each DMG; the public half ships inside the app and is what
refuses an update signed by anything else. Generate the pair once, with the
`generate_keys` tool from the Sparkle package Xcode already resolved:

```
# after any build of the app, so SPM has checked Sparkle out
find ~/Library/Developer/Xcode/DerivedData -path '*sparkle/Sparkle/bin/generate_keys' | head -1
```

It prints the public key and stores the private key in the login keychain. Then:

- Put the **public** key in `SU_PUBLIC_ED_KEY` in `Config/Shared.xcconfig` and
  commit it. Until that is done the value is the placeholder
  `replace_with_the_sparkle_public_key`, the app reports itself as having no
  updater, and the release workflow refuses to publish.
- Export the **private** key with `generate_keys -x -`, paste it into the
  `SPARKLE_ED_PRIVATE_KEY` secret, and keep an offline copy. Losing it means no
  existing installation can ever be updated again — a new key pair only reaches
  people who reinstall by hand.

### Rotating the certificate

The Developer ID Application certificate expires after five years; the workflow
warns for the last 30 days of that and fails once it has passed. Create a new one
in the Apple Developer portal, export it as `.p12` with its private key, and
replace `DEVELOPER_ID_CERT_P12_BASE64` and `DEVELOPER_ID_CERT_PASSWORD`. Nothing
already released is affected: notarized, stapled builds keep working after the
certificate that signed them expires.

## When something goes wrong

- **The push at the end failed.** The workflow rebases and retries three times,
  then fails loudly. The release is already public at that point, so the fix is
  to run `Scripts/release/append-appcast-item.sh` by hand against `main` with the
  values from the run's log, or simply re-add the entry — until the feed on
  `main` has it, nobody is offered the update.
- **Notarization was rejected.** Nothing was published. The `notarytool` log URL
  is in the step's output.
- **A release shipped with the wrong notes.** Edit
  `.changes/<version>.md`, run `changie merge`, re-render it, and replace the `<description>`
  of that entry in `.sparkle/appcast.xml`; the GitHub release body can be edited
  in place.
