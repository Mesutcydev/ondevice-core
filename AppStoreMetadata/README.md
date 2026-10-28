# Localized App Store pages

Prepared on October 16, 2026 for **OnDevice: Max**, App Store Connect app
**6818199563**, bundle `com.mesutcydev.ondevicemax`.

The six requested translations use the English (U.S.) metadata downloaded
from the existing iOS **1.0** record. The brand name and existing privacy,
support, and marketing URLs are preserved. Spanish uses the Spain locale.

| Language | ASC locale | Subtitle | App information | Version information |
| --- | --- | --- | --- | --- |
| Hindi | `hi` | लोकल AI, चैट, आवाज़ व चित्र | [Name and subtitle](localizations/app-info/hi.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/hi.json) |
| German | `de-DE` | Lokale KI: Chat, Stimme & Bild | [Name and subtitle](localizations/app-info/de-DE.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/de-DE.json) |
| Spanish (Spain) | `es-ES` | IA local, chat, voz e imágenes | [Name and subtitle](localizations/app-info/es-ES.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/es-ES.json) |
| Arabic | `ar-SA` | ذكاء محلي، دردشة وصوت وصور | [Name and subtitle](localizations/app-info/ar-SA.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/ar-SA.json) |
| Turkish | `tr` | Yerel AI: sohbet, ses, görsel | [Name and subtitle](localizations/app-info/tr.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/tr.json) |
| Japanese | `ja` | ローカルAI・チャット・音声・画像 | [Name and subtitle](localizations/app-info/ja.json) | [Description, promotion, keywords and URLs](localizations/version/1.0.1/ja.json) |

English source records are retained in the same folders. This is the first
App Store version, so there is no What's New field. Screenshots and creative
assets have not been uploaded or changed by this metadata operation.

## Validation

`asc metadata validate --dir AppStoreMetadata/localizations` passes for all
21 files with no errors or warnings (including the retained 1.0 source files). Every new subtitle is at most 30
characters, every description is under 4,000 characters, every promotional
text is at most 170 characters, and every localized keyword list is at most
100 UTF-8 bytes. The final authenticated dry run reports no remaining adds,
updates, or deletions.

## Save status

**Saved to ASC and verified on October 16, 2026.** All six requested locales
exist in both app information and iOS version 1.0.1. A fresh authenticated
download matches all **48 localized fields** to these source files. Both
English records also match the original download. All 14 records were checked.

The owner approved removing version 1.0 from review to make its metadata
editable. Submission `4886cf50-4729-48ec-81ee-8c6a57a6410f` finished cancellation
and now has state `COMPLETE`. The version was then renamed to **1.0.1** for
the fresh localization build **16**, as the owner requested. All seven locales
were read back and preserved after the rename. Build **1.0.1 (16)** is now
Apple-processed **VALID** and was submitted for review on October 16 at
**14:04:11 Europe/Istanbul**. The version and submission are both
**WAITING_FOR_REVIEW**. All seven locale records were verified again after
submission, and the selected build was read back as **16**.

The initial attempt while the version was `WAITING_FOR_REVIEW` was blocked by
Apple with:

> A relationship cannot be created in current state.

After the approved removal, creating app-information locales also caused
Apple to create empty version-localization records. A fresh lookup found
those records, and their description, keywords, promotional text, and URL
fields were then filled and verified. The final comparison has zero differences.

For future edits while the version is editable, preview and apply with the
configured owner API profile:

```sh
asc metadata apply --app 6818199563 --version 1.0.1 --platform IOS \
  --dir AppStoreMetadata/localizations --dry-run
asc metadata apply --app 6818199563 --version 1.0.1 --platform IOS \
  --dir AppStoreMetadata/localizations
```

Read back all six app-information and version-localization records and compare
every field to these files after saving. These commands do not submit a version
for review.

Evidence is retained under ignored `build/localization/asc-*` paths and
`build/localization-release-2026-10-16/`. See the
[build 16 release record](../Docs/APP_STORE_LOCALIZATION_BUILD16_2026-10-16.md).

References: [ASC app record](https://appstoreconnect.apple.com/apps/6818199563/distribution),
[Apple localization workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information),
[field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).
