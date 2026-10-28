"""Distribution policy regression tests; no credentials or portal calls."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import plistlib
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("verify_appstore", Path(__file__).parents[1] / "verify_appstore.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class ReviewFunnelTests(unittest.TestCase):
    def testRetiredFunnelRejectedRegardlessOfFilename(self):
        with self.assertRaisesRegex(ValueError, "review funnel"):
            verification.check_review_funnel('struct RenamedView { let title = "Enjoying Token AI?" }')

    def testNativeReviewRequestIsAllowed(self):
        verification.check_review_funnel('AppStore.requestReview(in: scene)')

    def testOrdinarySupportFeedbackIsAllowed(self):
        verification.check_review_funnel('Button("Report content concern") { showSupport = true }')


class LlamaNoticeTests(unittest.TestCase):
    def testSourceIncludesAgreementsAndRequiredNotices(self):
        verification.check_llama_notices(verification.ROOT / "LICENSES")

    def testMissingBundledNoticesAreRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "Models/meta-llama--Llama-3.1-8B-Instruct"
            model.mkdir(parents=True)
            (model / "LICENSE").write_text("Test agreement fixture")
            with self.assertRaisesRegex(ValueError, "notice missing"):
                verification.check_llama_notices(root)


class CandidateMetadataTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleShortVersionString": "1.0", "CFBundleVersion": "81",
                     "DTXcodeBuild": "27A266a", "DTPlatformName": "iphoneos", "DTSDKName": "iphoneos27.0"}

    def verify(self):
        verification.check_candidate_metadata(self.info, "1.0", "81", "27A266a")

    def testRequestedCandidateAccepted(self):
        self.verify()

    def testOlderUploadCannotPassAsCurrentCandidate(self):
        self.info["CFBundleVersion"] = "80"
        with self.assertRaisesRegex(ValueError, "CFBundleVersion expected 81"):
            self.verify()

    def testWrongMarketingVersionRejected(self):
        self.info["CFBundleShortVersionString"] = "1.1"
        with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
            self.verify()

    def testBetaToolchainRejected(self):
        self.info["DTXcodeBuild"] = "27A5218g"
        with self.assertRaisesRegex(ValueError, "DTXcodeBuild"):
            self.verify()

    def testMissingMetadataRejected(self):
        for key in ("CFBundleVersion", "DTXcodeBuild", "DTPlatformName", "DTSDKName"):
            with self.subTest(key=key):
                info = dict(self.info)
                del info[key]
                with self.assertRaises(ValueError):
                    verification.check_candidate_metadata(info, "1.0", "81", "27A266a")

    def testSimulatorAndCatalystCannotPassAsIOSCandidate(self):
        for platform, sdk in (("iphonesimulator", "iphonesimulator27.0"), ("macosx", "macosx27.0")):
            with self.subTest(platform=platform):
                self.info.update(DTPlatformName=platform, DTSDKName=sdk)
                with self.assertRaisesRegex(ValueError, "iOS device"):
                    self.verify()

    def testSimulatorSDKRejectedDespiteDevicePlatform(self):
        self.info["DTSDKName"] = "iphonesimulator27.0"
        with self.assertRaisesRegex(ValueError, "iPhoneOS SDK"):
            self.verify()


class EmbeddedFrameworkTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1", "MinimumOSVersion": "27.0"}

    def testValidFrameworkAndOlderSupportedDeploymentTarget(self):
        for minimum in ("8.0", "16.4", "27.0"):
            self.info["MinimumOSVersion"] = minimum
            verification.check_framework_metadata(self.info, "ODMiniCPM.framework", "27.0")

    def testMissingAndBlankFrameworkVersionsAreRejected(self):
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            for value in (None, "", " ", 1):
                with self.subTest(key=key, value=value):
                    info = dict(self.info, **{key: value})
                    with self.assertRaisesRegex(ValueError, key):
                        verification.check_framework_metadata(info, "ODMiniCPM.framework", "27.0")

    def testMissingBlankAndMalformedMinimumOSAreRejected(self):
        for value in (None, "", " ", "27.x", 27):
            with self.subTest(value=value):
                info = dict(self.info, MinimumOSVersion=value)
                with self.assertRaisesRegex(ValueError, "MinimumOSVersion"):
                    verification.check_framework_metadata(info, "ODMiniCPM.framework", "27.0")

    def testDeploymentTargetBefore64BitIOSIsRejected(self):
        self.info["MinimumOSVersion"] = "7.0"
        with self.assertRaisesRegex(ValueError, "64-bit"):
            verification.check_framework_metadata(self.info, "ODMiniCPM.framework", "27.0")

    def testFrameworkRequiringANewerOSThanTheAppIsRejected(self):
        self.info["MinimumOSVersion"] = "27.1"
        with self.assertRaisesRegex(ValueError, "exceeds"):
            verification.check_framework_metadata(self.info, "ODMiniCPM.framework", "27.0")

    def testNestedShareExtensionFrameworkIsAlsoChecked(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            framework = app / "PlugIns/Share.appex/Frameworks/ODMiniCPM.framework"
            framework.mkdir(parents=True)
            with (framework / "Info.plist").open("wb") as stream:
                plistlib.dump(dict(self.info, CFBundleVersion=""), stream)
            with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
                verification.check_embedded_frameworks(app, "27.0")


class DistributionProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.team = "ABCDE12345"
        self.bundle = verification.APP_ID
        self.entitlements = verification.read_plist(verification.ROOT / "IOSLocalLLM/IOSLocalLLM-AppStore.entitlements")
        self.entitlements.update({"application-identifier": "LEGACY1234." + self.bundle,
                                  "com.apple.developer.team-identifier": self.team,
                                  "get-task-allow": False})
        self.profile = {"TeamIdentifier": [self.team], "ApplicationIdentifierPrefix": ["LEGACY1234"],
                        "ExpirationDate": self.now + timedelta(days=30),
                        "Entitlements": copy.deepcopy(self.entitlements)}

    def verify(self):
        verification.check_distribution_profile(self.profile, self.entitlements, self.bundle, self.team, self.now)

    def testExplicitAppStoreProfileWithLegacyAppIDPrefix(self):
        self.verify()

    def testDownloadWidgetProfileNeedsNoSharedModelStorage(self):
        self.bundle = verification.APP_ID + ".Downloads"
        self.entitlements = {"application-identifier": "LEGACY1234." + self.bundle,
                             "com.apple.developer.team-identifier": self.team, "get-task-allow": False}
        self.profile["Entitlements"] = copy.deepcopy(self.entitlements)
        self.verify()
        self.entitlements["com.apple.security.application-groups"] = [verification.GROUP]
        with self.assertRaisesRegex(ValueError, "storage access"):
            self.verify()

    def testShareExtensionStillRequiresItsAppGroup(self):
        self.bundle = verification.APP_ID + ".Share"
        self.entitlements["application-identifier"] = "LEGACY1234." + self.bundle
        self.profile["Entitlements"]["application-identifier"] = "LEGACY1234." + self.bundle
        self.entitlements.pop("com.apple.security.application-groups")
        with self.assertRaisesRegex(ValueError, "App Group"):
            self.verify()

    def testProfileMayStillGrantCloudKit(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        self.verify()

    def testSignedICloudEntitlementsRejected(self):
        for key, value in (("com.apple.developer.icloud-services", ["CloudKit"]),
                           ("com.apple.developer.icloud-container-identifiers", ["iCloud." + verification.APP_ID]),
                           ("com.apple.developer.icloud-container-environment", "Production"),
                           ("com.apple.developer.ubiquity-kvstore-identifier", "TEAM.store")):
            with self.subTest(key=key):
                self.entitlements[key] = value
                self.profile["Entitlements"][key] = value
                with self.assertRaisesRegex(ValueError, "iCloud"):
                    self.verify()
                self.entitlements.pop(key)

    def testRejectsExpiredProfile(self):
        self.profile["ExpirationDate"] = self.now - timedelta(seconds=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.verify()

    def testRejectsDevelopmentAdHocAndEnterpriseProfiles(self):
        for attribute, value in (("ProvisionedDevices", []), ("ProvisionsAllDevices", True)):
            with self.subTest(attribute=attribute):
                self.profile[attribute] = value
                with self.assertRaises(ValueError):
                    self.verify()
                del self.profile[attribute]

    def testRejectsDebuggingEntitlements(self):
        for key in ("get-task-allow", verification.DEBUG_MEMORY):
            with self.subTest(key=key):
                self.entitlements[key] = True
                with self.assertRaises(ValueError):
                    self.verify()
                self.entitlements.pop(key)

    def testRejectsWrongTeamAndWildcardIdentity(self):
        self.profile["TeamIdentifier"] = ["OTHER12345"]
        with self.assertRaisesRegex(ValueError, "team"):
            self.verify()
        self.profile["TeamIdentifier"] = [self.team]
        self.profile["Entitlements"]["application-identifier"] = "LEGACY1234.*"
        with self.assertRaisesRegex(ValueError, "App ID"):
            self.verify()

    def testManagedPCCRequiresProfileGrant(self):
        self.entitlements["com.apple.developer.private-cloud-compute"] = True
        with self.assertRaisesRegex(ValueError, "Profile does not grant"):
            self.verify()
        self.profile["Entitlements"]["com.apple.developer.private-cloud-compute"] = True
        self.verify()

    def testRejectsWrongAppGroup(self):
        self.entitlements["com.apple.security.application-groups"] = ["group.wrong"]
        with self.assertRaisesRegex(ValueError, "App Group"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
