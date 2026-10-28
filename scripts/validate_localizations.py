#!/usr/bin/env python3
"""Check shipped localization coverage and format arguments without Xcode."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("hi", "de", "es", "ar", "tr", "ja")
CATALOGS = (
    ROOT / "Packages/OnDeviceUI/Sources/OnDeviceUI/Resources/Localizable.xcstrings",
    ROOT / "IOSLocalLLM/Resources/Localization/InfoPlist.xcstrings",
)
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|h|l|L|z|t|j)?([@diuoxXfFeEgGaAcCsSp%])")


def arguments(value):
    return Counter((length or "") + kind for _, length, kind in FORMAT.findall(value) if kind != "%")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def validate(path):
    catalog = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    errors = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        source = localizations.get("en", {}).get("stringUnit", {}).get("value", key)
        for language in LANGUAGES:
            unit = localizations.get(language, {}).get("stringUnit", {})
            value = unit.get("value", "")
            if not value.strip() or unit.get("state") != "translated":
                errors.append(f"{language}: missing translation for {key!r}")
            elif arguments(value) != arguments(source):
                errors.append(f"{language}: changed format arguments for {key!r}")
    return len(catalog["strings"]), errors


def missing_package_keys():
    catalog = json.loads(CATALOGS[0].read_text(encoding="utf-8"))["strings"]
    missing = set()
    # Static package labels must be registered, including deliberately
    # untranslated brand/sample keys. Interpolated keys are compiler-extracted
    # and their format arguments are checked above.
    pattern = re.compile(r'\b(?:Text|ODLocalizedString)\(\s*("(?:[^"\\]|\\.)*")')
    sources = ROOT / "Packages/OnDeviceUI/Sources/OnDeviceUI"
    for path in sources.rglob("*.swift"):
        for match in pattern.finditer(path.read_text(encoding="utf-8")):
            try:
                key = json.loads(match[1])
            except ValueError:
                continue  # Swift interpolation is not a JSON literal.
            if re.search(r"[A-Za-z]", key) and key not in catalog:
                missing.add(key)
    return sorted(missing)


def validate_bundles(app):
    catalog = json.loads(CATALOGS[0].read_text(encoding="utf-8"))["strings"]
    extensions = sorted((app / "PlugIns").glob("*.appex"))
    if len(extensions) != 2:
        raise ValueError("expected share and download activity extensions")
    bundles = [app, app / "OnDeviceUI_OnDeviceUI.bundle", *extensions]
    for bundle in bundles:
        for language in LANGUAGES:
            path = bundle / f"{language}.lproj/Localizable.strings"
            with path.open("rb") as stream:
                compiled = plistlib.load(stream)
            for key, entry in catalog.items():
                if entry.get("shouldTranslate") is False:
                    continue
                expected = entry["localizations"][language]["stringUnit"]["value"]
                if compiled.get(key) != expected:
                    raise ValueError(f"{path}: missing or stale translation for {key!r}")
    for language in LANGUAGES:
        with (app / f"{language}.lproj/InfoPlist.strings").open("rb") as stream:
            permissions = plistlib.load(stream)
        if len(permissions) != 6:
            raise ValueError(f"{language}: missing localized permission messages")
    print("Compiled translations verified in app, package, and both extensions.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=Path, help="also verify all compiled shipping bundles")
    args = parser.parse_args()
    total = 0
    for path in CATALOGS:
        count, errors = validate(path)
        total += count
        if errors:
            print(f"{path.relative_to(ROOT)}:", file=sys.stderr)
            print("\n".join(errors), file=sys.stderr)
            return 1
    missing = missing_package_keys()
    if missing:
        print(f"Package UI keys missing from the catalog: {missing}", file=sys.stderr)
        return 1
    if args.app_bundle:
        validate_bundles(args.app_bundle)
    print(f"Localization checks passed: {total} keys, {len(LANGUAGES)} requested languages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
