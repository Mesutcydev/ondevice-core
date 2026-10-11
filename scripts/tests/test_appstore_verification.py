"""Distribution policy regression tests; no credentials or portal calls."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("verify_appstore", Path(__file__).parents[1] / "verify_appstore.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class ReviewFunnelTests(unittest.TestCase):
    def testRetiredFunnelRejectedRegardlessOfFilename(self):
        with self.assertRaisesRegex(ValueError, "review funnel"):
            verification.check_review_funnel('struct RenamedView { let title = "Enjoying OnDevice?" }')

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


class DistributionProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.team = "ABCDE12345"
        self.bundle = verification.APP_ID
        self.entitlements = verification.read_plist(verification.ROOT / "IOSLocalLLM/IOSLocalLLM-AppStore.entitlements")
        self.entitlements.update({"application-identifier": "LEGACY1234." + self.bundle,
                                  "com.apple.developer.team-identifier": self.team,
                                  "com.apple.developer.icloud-container-environment": "Production",
                                  "get-task-allow": False})
        self.profile = {"TeamIdentifier": [self.team], "ApplicationIdentifierPrefix": ["LEGACY1234"],
                        "ExpirationDate": self.now + timedelta(days=30),
                        "Entitlements": copy.deepcopy(self.entitlements)}

    def verify(self):
        verification.check_distribution_profile(self.profile, self.entitlements, self.bundle, self.team, self.now)

    def testExplicitAppStoreProfileWithLegacyAppIDPrefix(self):
        self.verify()

    def testAppleCloudKitProfileAllowlistAndServiceWildcard(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        self.verify()

    def testCloudKitAllowlistMustAuthorizeProduction(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Development"]
        with self.assertRaisesRegex(ValueError, "Profile does not grant"):
            self.verify()

    def testWildcardServiceDoesNotAllowOtherSignedServices(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        for value in (["CloudDocuments"], ["CloudKit", "CloudDocuments"], ["*"], "*"):
            with self.subTest(value=value):
                self.entitlements["com.apple.developer.icloud-services"] = value
                with self.assertRaisesRegex(ValueError, "CloudKit"):
                    self.verify()

    def testMissingOrUnrelatedCloudKitGrantRejected(self):
        key = "com.apple.developer.icloud-services"
        for value in (None, ["CloudDocuments"], "CloudDocuments"):
            with self.subTest(value=value):
                self.profile["Entitlements"][key] = value
                with self.assertRaisesRegex(ValueError, "Profile does not grant"):
                    self.verify()

    def testDevelopmentSignatureRejectedDespiteProfileAllowlist(self):
        key = "com.apple.developer.icloud-container-environment"
        self.profile["Entitlements"][key] = ["Production", "Development"]
        self.entitlements[key] = "Development"
        with self.assertRaisesRegex(ValueError, "Production"):
            self.verify()

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

    def testRejectsWrongAppGroupAndDevelopmentCloudKit(self):
        self.entitlements["com.apple.security.application-groups"] = ["group.wrong"]
        with self.assertRaisesRegex(ValueError, "App Group"):
            self.verify()
        self.entitlements["com.apple.security.application-groups"] = [verification.GROUP]
        self.entitlements["com.apple.developer.icloud-container-environment"] = "Development"
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Development"
        with self.assertRaisesRegex(ValueError, "Production"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
