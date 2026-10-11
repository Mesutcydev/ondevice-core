# Release verification

Official releases contain source only. They do not contain an App Store build,
signed IPA, generated native framework, or model weights.

Starting with `v3.2.6`, the `Source release` GitHub Actions workflow creates a
reproducible source archive from the tagged commit, publishes its SHA-256
checksum, and records a GitHub artifact attestation backed by Sigstore.

## Download and verify

Install the [GitHub CLI](https://cli.github.com/), then download a release:

```bash
gh release download v3.2.6 \
  --repo Mesutcydev/ios-local-llm \
  --pattern 'ios-local-llm-*-source.tar.gz*'
```

Verify its checksum:

```bash
shasum -a 256 \
  --check ios-local-llm-3.2.6-source.tar.gz.sha256
```

Verify that GitHub Actions produced the archive from this repository:

```bash
gh attestation verify \
  ios-local-llm-3.2.6-source.tar.gz \
  --repo Mesutcydev/ios-local-llm
```

The attestation proves the workflow identity and artifact digest. It does not
change the licenses of the source, dependencies, or separately downloaded
models. Review `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `PROVENANCE.md` before
redistribution.

## Local sideload IPA release scheme

This is separate from the public source-only GitHub release above. Use it only
when a user explicitly requests a local IPA artifact.

The reproducible profile-less release command is:

```bash
./scripts/build_sideload_ipa.sh build/releases
```

The script must run with Xcode 27 and performs the complete release contract:

1. Regenerate the Xcode project from `project.yml` and install CocoaPods.
2. Verify catalog invariants and every direct Core AI model URL.
3. Archive the `OnDeviceMax` scheme in `Release` for generic iOS with
   signing disabled.
4. Reject unsafe Foundation Models imports and confirm Core AI linkage.
5. Verify the bundle ID, display name, version/build, iOS 27 minimum, privacy
   manifest, share extension, llama framework, and whisper framework.
6. Ad-hoc sign nested frameworks, the share extension, and the app using
   `IOSLocalLLM-PCC.entitlements` and the share-extension entitlements.
7. Verify that the IPA root contains only `Payload/`, signatures are valid,
   required entitlements match exactly, and no provisioning profile is present.
8. Emit versioned and `latest` IPA files plus size and SHA-256 output.

This artifact is re-signer-ready, not directly installable. AltStore,
SideStore, a CI signer, or another installer must apply a valid certificate and
profiles for both the app and share extension. Do not add IPA files, archives,
profiles, certificates, or signing credentials to Git.

If valid Apple profiles already exist for both bundle IDs, preserve the signed
archive and package it with `scripts/package_sideloadable_ipa.sh` instead; that
path verifies and retains the embedded profile and signed entitlements.

## Local App Store export

The App Store path uses distribution profiles for both the app and share
extension. Read [the compliance audit](APP_STORE_COMPLIANCE_AUDIT_2026-10-01.md)
and resolve its open findings before treating an export as a release candidate.
Packaging verification checks the artifact structure and signing; it does not
approve model licenses, content safety, or App Store metadata.

Select shipping Xcode and check the local prerequisites first:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/build_appstore.sh --preflight YOUR_TEAM_ID
```

Fresh builds require 15 GiB of free space. To reuse a shipping build cache, set
`ONDEVICE_DERIVED_DATA` to its existing DerivedData directory. If the cached app
matches the selected toolchain and iPhoneOS SDK, the script calculates a working
budget from its build/app sizes with a 6 GiB minimum. Pending shared first-launch
setup is reported as a notice; the device archive/export must still succeed.
The script never runs license acceptance.

After the prerequisites and compliance findings are resolved, omit
`--preflight` to archive and export locally. The script uses automatic signing,
checks the app and extension's distribution profiles, and writes the IPA and
checksum under the ignored `build/appstore/` directory. It does not upload or
submit the app.

Release defaults to `IOSLocalLLM-AppStore.entitlements`, which omits debugging
memory and Private Cloud Compute. Use `--enable-pcc` only after confirming
Apple's managed capability grant for the same App ID and team. CloudKit's
production schema also needs verification before enabling sync in production.

Public Release builds compile `APP_STORE` model policy, reject confirmed
FastVLM/Youtu identities, exclude the FastVLM encoder, and use the bundled
`AuditedModelRevisions.json` for new network downloads. Unknown revisions are
refused. These checks record source provenance; they do not approve model
licenses or prove the contents of old caches or user imports. Release notice
collection preserves the model legal texts under `LICENSES/Models/`.

The explicit sideload script selects `RESEARCH_MODE` and
`ONDEVICE_RESEARCH_BUILD=YES`. Its research artifacts and permissions are not
an App Store candidate. Image generation remains available in the public app;
parents can restrict it with the device-only PIN in Settings. Validate both
restricted and allowed behavior on the signed production candidate.

The preflight currently expects Xcode 27 build `27A266a`, reverified against
[Apple's releases](https://developer.apple.com/news/releases/) on 2026-10-09.
Change `ONDEVICE_APPSTORE_XCODE_BUILD` only after verifying that a replacement
toolchain is accepted for App Store distribution. Preserve existing exports,
use an unused build number, and keep generated signing material out of Git.

The archive uses `-onlyUsePackageVersionsFromResolvedFile` and
`-skipPackageUpdates`. Review and update both checked-in lockfiles before
changing dependencies; packaging must not select different versions during
the release build. The PrismML core fork remains required for Bonsai 1-bit.
Set `ONDEVICE_SOURCE_PACKAGES` to reuse the same reviewed package cache for
device validation and archiving; it defaults to `SourcePackages` inside the
selected DerivedData directory.

For Xcode's documented API-key signing authentication, set all three of
`ONDEVICE_ASC_KEY_PATH`, `ONDEVICE_ASC_KEY_ID` and `ONDEVICE_ASC_ISSUER_ID`.
The script passes them to archive and export without reading or copying the
private key into the repository. Without them, Xcode uses its existing account
and signing setup. A partial configuration fails preflight.

The latest candidate audit is [the October 9 release audit](APP_STORE_RELEASE_AUDIT_2026-10-09.md).
Its TestFlight checks and remaining public-release conditions are recorded
separately. Uploading a beta does not close the public App Review conditions.

## TestFlight upload

After candidate verification and signed App Store export, use Xcode Organizer,
Transporter, or the official App Store Connect upload API. Verify the existing
app record by the exact `com.mesutcydev.ondevicemax` bundle ID and inspect its
uploaded builds before choosing an unused build number. Refresh owner-team
authentication and signing first; an invalid API key or revoked certificate
cannot upload a new signed candidate.

Xcode's authenticated Apple Account can upload without the CLI API key. Copy
the verified export's `ExportOptions.plist` to `UploadOptions.plist`, change only
`destination` to `upload`, and preserve the owner team, automatic signing,
Production CloudKit, and fixed build number. Then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -exportArchive -archivePath PATH_TO_VERIFIED_ARCHIVE \
  -exportOptionsPlist PATH_TO_UPLOAD_OPTIONS -allowProvisioningUpdates
```

If Apple reports that the exact bundle's app record is missing, establish that
record in the owner account before retrying. Check the bundle ID of any older
listing before associating this product with it.

With authenticated official API access, the installed `asc` CLI can perform the
upload:

```bash
asc apps list --bundle-id com.mesutcydev.ondevicemax --limit 1
asc builds list --app APP_ID --version 1.0 --sort -uploadedDate --limit 10
asc builds upload --app APP_ID --ipa PATH_TO_VERIFIED_IPA --checksum --verify-timeout 45s
asc builds list --app APP_ID --version 1.0 --build-number BUILD_NUMBER
```

Retain the upload result and verify that Apple reports the build as processed
and valid. An accepted upload alone does not establish that processing passed.
Public App Store submission and tester invitations are separate actions.
Use Apple's documented upload interfaces for this workflow.
[Apple upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
