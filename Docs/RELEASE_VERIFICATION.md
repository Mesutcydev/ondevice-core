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
3. Archive the `OnDeviceCoreAIStudio` scheme in `Release` for generic iOS with
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


## Data-preserving updates (downloaded models survive)

The sideload IPA is profile-less and ad-hoc signed, so the installer must
re-sign it. Whether an update keeps `Documents/LLMModels` depends entirely on
that install path:

- **Preserved** when the app is updated in place with the same
  `TeamIdentifier.BundleIdentifier` (same Apple ID/team, same bundle id) and
  the installer does not delete the app first. Preferred paths: Xcode
  `Product > Run`, or
  `xcrun devicectl device install app --device <UDID> <signed .app>`.
- **Lost** when the installer uninstalls first, or re-signs with a different
  application identifier. iOS then gives the app a fresh, empty container and
  the multi-GB model downloads are gone.

Tooling:

- `scripts/verify_ipa_identity.sh <ipa>` — checks the bundle id/version,
  signing style and entitlements, and prints the preservation checklist.
- App > Diagnostics > **Deployment Persistence** — write a sentinel in build A,
  install build B as an update, then Check. A missing sentinel proves the
  container was deleted by the install path.
- Recovery without re-downloading: keep one copy of a model folder in the
  Files app / iCloud Drive and use Models > Import after a wipe.
