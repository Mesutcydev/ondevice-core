#!/usr/bin/env python3
"""Check Token AI source or a built bundle before App Store export."""
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "com.token.TokenAI"
GROUP = "group.com.token.TokenAI"
DEBUG_MEMORY = "com.apple.developer.kernel.increased-debugging-memory-limit"
ICLOUD_PREFIXES = ("com.apple.developer.icloud", "com.apple.developer.ubiquity")


def read_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_review_funnel(source):
    """Reject the retired sentiment-gated flow, even if its file is renamed.

    Apple's native requestReview API remains allowed. This regression check
    covers the known rejected implementation, not every conceivable funnel.
    """
    for marker in ("ReviewPromptService", "ReviewPromptSheet", "review.didRequestReview",
                   "Love it — rate on App Store", "Enjoying Token AI?"):
        require(marker not in source, "Custom App Store review funnel was reintroduced: " + marker)


def check_llama_notices(licenses):
    for name, agreement, version in (
            ("meta-llama--Llama-3.1-8B-Instruct", "LICENSE", "3.1"),
            ("meta-llama--Meta-Llama-3.1-8B", "LICENSE", "3.1"),
            ("meta-llama--Llama-3.2-3B-Instruct", "LICENSE.txt", "3.2")):
        directory = licenses / "Models" / name
        require((directory / agreement).is_file() and (directory / agreement).stat().st_size > 0,
                "Required Llama agreement missing: " + name)
        notice = directory / "NOTICE"
        expected = (f"Llama {version} is licensed under the Llama {version} Community License, "
                    "Copyright © Meta Platforms, Inc. All Rights Reserved.")
        require(notice.is_file() and expected in " ".join(notice.read_text().split()),
                "Required Llama notice missing: " + name)


def check_candidate_metadata(info, expected_version=None, expected_build=None, expected_xcode_build=None):
    """Tie an archive/export to the requested candidate, rather than any old build."""
    for key, expected in (("CFBundleShortVersionString", expected_version),
                          ("CFBundleVersion", expected_build),
                          ("DTXcodeBuild", expected_xcode_build)):
        if expected is not None:
            require(info.get(key) == expected,
                    f"Candidate mismatch: {key} expected {expected}, found {info.get(key)}")
    require(info.get("DTPlatformName") == "iphoneos", "Candidate must be built for an iOS device")
    require(str(info.get("DTSDKName", "")).startswith("iphoneos"), "Candidate must use the iPhoneOS SDK")


def check_framework_metadata(info, name, app_minimum_os):
    """Framework plists must pass the same required-field checks as the app."""
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key)
        require(isinstance(value, str) and bool(value.strip()), f"{name}: {key} is missing or blank")
    minimum = info.get("MinimumOSVersion")
    require(isinstance(minimum, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", minimum),
            f"{name}: MinimumOSVersion is missing or invalid")
    def version(value):
        parts = [int(part) for part in value.split(".")]
        return tuple(parts + [0] * (3 - len(parts)))
    require(version(minimum) >= (8, 0, 0), f"{name}: MinimumOSVersion must support 64-bit iOS")
    require(version(minimum) <= version(app_minimum_os),
            f"{name}: MinimumOSVersion exceeds the app deployment target")


def check_embedded_frameworks(app, app_minimum_os):
    for framework in sorted(app.rglob("*.framework")):
        check_framework_metadata(read_plist(framework / "Info.plist"),
                                 str(framework.relative_to(app)), app_minimum_os)


def check_distribution_profile(profile, entitlements, bundle_id, team_id, now=None):
    """Validate final export; a development-signed archive must be re-signed."""
    now = now or datetime.now(timezone.utc)
    expires = profile["ExpirationDate"]
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    require(expires > now, "Provisioning profile expired")
    require(team_id in profile.get("TeamIdentifier", []), "Profile belongs to another team")
    require("ProvisionedDevices" not in profile, "Device provisioning profile is not App Store distribution")
    require(not profile.get("ProvisionsAllDevices"), "Enterprise profile is not App Store distribution")
    granted = profile["Entitlements"]
    require(not granted.get("get-task-allow"), "Profile permits debugging")
    require(not entitlements.get("get-task-allow"), "Exported app permits debugging")
    require(DEBUG_MEMORY not in entitlements, "Debugging memory entitlement must be removed")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(bool(prefixes), "Profile has no App ID prefix")
    app_identifier = prefixes[0] + "." + bundle_id
    require(granted.get("application-identifier") == app_identifier, "Profile does not match the explicit App ID")
    require(entitlements.get("application-identifier") == app_identifier, "Signed App ID does not match its profile")
    require(entitlements.get("com.apple.developer.team-identifier") == team_id, "Signed team does not match")
    if bundle_id == APP_ID + ".Downloads":
        require(not entitlements.get("com.apple.security.application-groups"), "Download widget must not claim model storage access")
    else:
        require(entitlements.get("com.apple.security.application-groups") == [GROUP], "Signed App Group does not match")
    for key, value in entitlements.items():
        if key.startswith("com.apple.") and key != "com.apple.developer.team-identifier":
            permission = granted.get(key)
            # A profile is an authorization allowlist, not a copy of the
            # signature (Apple TN3125): it may grant more than the app claims.
            if isinstance(value, list) and isinstance(permission, list):
                require(all(item in permission for item in value), f"Profile does not grant {key}")
            else:
                require(permission == value, f"Profile does not grant {key}")
    if bundle_id == APP_ID:
        for key in ("com.apple.developer.kernel.increased-memory-limit",
                    "com.apple.developer.kernel.extended-virtual-addressing"):
            require(entitlements.get(key) is True, f"Required runtime entitlement missing: {key}")
    # The app has no iCloud feature; profiles may still grant the capability.
    require(not any(key.startswith(ICLOUD_PREFIXES) for key in entitlements),
            "iCloud entitlements must not ship: the app has no iCloud feature")


def check_manifest(path, required_categories):
    manifest = read_plist(path)
    require(manifest.get("NSPrivacyTracking") is False, f"Unexpected tracking: {path}")
    entries = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
               for entry in manifest.get("NSPrivacyAccessedAPITypes", [])}
    for category in required_categories:
        require(bool(entries.get("NSPrivacyAccessedAPICategory" + category)),
                f"Privacy reason missing for {category}: {path}")


def check_source():
    local = read_plist(ROOT / "IOSLocalLLM/IOSLocalLLM-AppStore.entitlements")
    pcc = read_plist(ROOT / "IOSLocalLLM/IOSLocalLLM-AppStore-PCC.entitlements")
    for entitlements in (local, pcc):
        require(DEBUG_MEMORY not in entitlements, "Distribution source contains debugging memory entitlement")
        require(entitlements["com.apple.security.application-groups"] == [GROUP], "Distribution App Group mismatch")
        require(entitlements["com.apple.developer.kernel.increased-memory-limit"] is True, "Runtime memory capability missing")
        require(entitlements["com.apple.developer.kernel.extended-virtual-addressing"] is True, "Runtime addressing capability missing")
        require(not any(key.startswith(ICLOUD_PREFIXES) for key in entitlements), "Distribution source claims iCloud")
    expected = dict(local, **{"com.apple.developer.private-cloud-compute": True})
    require(pcc == expected, "PCC variant must differ only by the managed PCC entitlement")
    check_manifest(ROOT / "IOSLocalLLM/PrivacyInfo.xcprivacy", ["UserDefaults", "FileTimestamp", "DiskSpace", "SystemBootTime"])
    check_manifest(ROOT / "IOSLocalLLMShareExtension/PrivacyInfo.xcprivacy", ["FileTimestamp"])
    check_manifest(ROOT / "DownloadActivityExtension/PrivacyInfo.xcprivacy", [])
    config = (ROOT / "project.yml").read_text()
    require('ONDEVICE_MODEL_POLICY: APP_STORE' in config, "Public model policy is not the default")
    require('$(ONDEVICE_MODEL_POLICY)' in config, "Release does not compile the public model policy")
    require((ROOT / "IOSLocalLLM/Services/ReviewPromptService.swift").exists() is False,
            "Custom App Store review funnel was reintroduced")
    for directory in (ROOT / "IOSLocalLLM", ROOT / "Packages/OnDeviceUI/Sources"):
        for path in directory.rglob("*.swift"):
            check_review_funnel(path.read_text())
    check_llama_notices(ROOT / "LICENSES")
    revisions = json.loads((ROOT / "IOSLocalLLM/Resources/AuditedModelRevisions.json").read_text())
    require(bool(revisions) and all(re.fullmatch(r"[0-9a-f]{40}", value) for value in revisions.values()),
            "Invalid model source revision inventory")
    print("App Store source checks passed")


def signed_entitlements(bundle):
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)],
                            capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def check_bundle(app, team_id, distribution, expected_version=None, expected_build=None, expected_xcode_build=None):
    app = app.resolve()
    info = read_plist(app / "Info.plist")
    check_candidate_metadata(info, expected_version, expected_build, expected_xcode_build)
    require(info["CFBundleIdentifier"] == APP_ID, "Wrong app bundle ID")
    require(info.get("CFBundleDisplayName") == "Token AI", "Wrong display name")
    require(info.get("MinimumOSVersion") == "27.0", "Unexpected minimum OS")
    require(info.get("ITSAppUsesNonExemptEncryption") is False, "Export-compliance declaration missing")
    require(info.get("UIFileSharingEnabled") and info.get("LSSupportsOpeningDocumentsInPlace"), "Files access flags missing")
    require((app / "THIRD-PARTY-NOTICES.txt").is_file(), "Resolved dependency notices missing")
    require((app / "AuditedModelRevisions.json").is_file(), "Model source revision inventory missing")
    require((app / "LICENSES").is_dir(), "License texts missing")
    check_llama_notices(app / "LICENSES")
    for framework in ("llama", "whisper"):
        require((app / "Frameworks" / (framework + ".framework")).is_dir(), f"{framework} framework missing")
    for path in app.rglob("*"):
        require(not path.is_symlink() or path.resolve().is_relative_to(app), "Bundle symlink escapes app")
        require(path.name.lower() not in ("fastvithd.mlmodelc", "fastvithd.mlpackage", "fastvlm-0.5b-fp16"),
                "Research-only FastVLM artifacts cannot ship in the App Store build")
        require(path.suffix.lower() not in (".p8", ".p12", ".pem", ".key", ".pkg", ".ipa"),
                f"Unexpected credential/installer artifact: {path.name}")
    check_embedded_frameworks(app, info["MinimumOSVersion"])
    extension = app / "PlugIns/TokenAIShare.appex"
    ext_info = read_plist(extension / "Info.plist")
    check_candidate_metadata(ext_info, expected_version, expected_build, expected_xcode_build)
    require(ext_info["CFBundleIdentifier"] == APP_ID + ".Share", "Wrong extension bundle ID")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(info[key] == ext_info[key], f"App/extension mismatch: {key}")
    widget = app / "PlugIns/TokenAIDownloads.appex"
    widget_info = read_plist(widget / "Info.plist")
    check_candidate_metadata(widget_info, expected_version, expected_build, expected_xcode_build)
    require(widget_info["CFBundleIdentifier"] == APP_ID + ".Downloads", "Wrong download widget bundle ID")
    require(widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
            "Download widget extension is not configured for WidgetKit")
    require(info.get("NSSupportsLiveActivities") is True, "Live Activities are not enabled")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"):
        require(info[key] == widget_info[key], f"App/widget mismatch: {key}")
    for bundle, categories in ((app, ["UserDefaults", "FileTimestamp", "DiskSpace", "SystemBootTime"]),
                               (extension, ["FileTimestamp"]), (widget, [])):
        check_manifest(bundle / "PrivacyInfo.xcprivacy", categories)
        if distribution:
            require(bool(team_id), "Team ID required for signed distribution verification")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
            profile = subprocess.run(["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")],
                                     capture_output=True, check=True)
            check_distribution_profile(plistlib.loads(profile.stdout), signed_entitlements(bundle),
                                       read_plist(bundle / "Info.plist")["CFBundleIdentifier"], team_id)
    print("App Store bundle checks passed" + (" (signed distribution)" if distribution else " (resources only)"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--team-id")
    parser.add_argument("--distribution", action="store_true")
    parser.add_argument("--expected-version", help="Require the requested marketing version")
    parser.add_argument("--expected-build", help="Require the requested build number")
    parser.add_argument("--expected-xcode-build", help="Require the approved distribution toolchain")
    args = parser.parse_args()
    if not args.source and args.app is None:
        parser.error("Specify --source or --app")
    if args.app is None and any((args.expected_version, args.expected_build, args.expected_xcode_build)):
        parser.error("Candidate expectations require --app")
    try:
        if args.source:
            check_source()
        if args.app:
            check_bundle(args.app, args.team_id, args.distribution,
                         args.expected_version, args.expected_build, args.expected_xcode_build)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
