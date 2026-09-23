# Xcode security settings

Security build-setting decisions for iOS Local LLM. `project.yml` is the source
of truth; generated Xcode project files mirror it.

## Enabled settings

- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`: missing returns are defects.
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`: catches unsafe reads.
- `CLANG_WARN_IMPLICIT_FALLTHROUGH` to `YES`: catches switch logic errors.
- `GCC_WARN_64_TO_32_BIT_CONVERSION` to `YES`: reports truncation.
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS` to `YES`: prevents
  incorrect C function assumptions.
- `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER` to `YES`.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND` to `YES`.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY` to `YES`.

These checks are high-confidence and have no runtime cost.

## Accepted build constraints

- `ENABLE_USER_SCRIPT_SANDBOXING` is disabled because the model-bundling build
  phases mirror variable directory trees into `TARGET_BUILD_DIR`; XcodeGen
  cannot declare that changing output set per script. Release artifacts are
  still produced only from reviewed, repository-local scripts and inputs.
- `ENABLE_TESTABILITY` is enabled only for Debug. Release and archive builds
  explicitly disable it.

## Deferred

- `ENABLE_ENHANCED_SECURITY` and its hardened-process entitlements: defer until
  the app target, extensions, Catalyst entitlements, CocoaPods, and generated
  llama.cpp/whisper.cpp frameworks have a complete device and Catalyst test
  matrix.
- `ENABLE_POINTER_AUTHENTICATION`: external XCFramework slices are currently
  built for arm64, not a verified arm64e distribution. Enabling this only for
  app code would not establish end-to-end compatibility.
- C bounds safety and C++ unsafe-buffer adoption: native inference code is
  pinned in upstream submodules and compiled into external frameworks. Adopt
  with upstream-compatible annotations and dedicated testing.
- Hardware memory tagging: hardware support and performance impact require a
  staged physical-device rollout.
- Higher-noise conversion, enum, sign-compare, and experimental buffer
  diagnostics: evaluate after the baseline warnings remain clean.

## Dependency identity alignment

`mlx-swift-lm` requests the upstream MLX URL transitively, while catalog
presets require the pinned PrismML fork for one-bit kernels. Each shared Xcode
workspace includes a SwiftPM mirror configuration that maps the upstream URL
to the PrismML fork. This removes the duplicate-identity warning and keeps all
direct and transitive MLX products on one audited revision. Do not remove the
workspace mirror without first removing the one-bit dependency.
