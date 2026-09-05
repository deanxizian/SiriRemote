# Contributing

SiriRemote intentionally supports one hardware target and one fixed control layout. Before opening
a change, please keep the scope aligned with the boundaries in `README.md` and explain any proposed
expansion in an issue first.

## Development checks

Run the portable checks before submitting a pull request:

```sh
swift test --package-path SiriRemoteCore
(cd app && ./build.sh && ./SiriRemote --verify-config)
(cd mic && ./build-test.sh)
(cd mic/captured && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
(cd mic/driver && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
(cd mic/router && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
```

The App build links Apple's private `MultitouchSupport.framework`, so it must run on macOS. Hardware
and permission behavior cannot be exercised in GitHub Actions and must be described in the pull
request when tested locally.

HAL tests load the bundle in-process with private user-only shared memory, including sanitized
cold-attach, revoked-generation and sealed-drain regressions. Never point fixtures at production
PCM. Capture tests exercise kernel XPC message identity and reject forged product metadata. The
pure Doubao session engine is the same implementation compiled into the App, not a test-only model.
Changes to shared ABI or Capture control require a full component install, not an App-only reload.

Official local deployments and packages require the maintainer's stable Developer ID identity.
Never replace that workflow with ad-hoc signing in a release change. Contributors without that
identity can still run the source and Core checks above.

## Pull requests

- Keep changes focused and include tests for pure state-machine behavior.
- Treat every synthetic key or mouse down as an owned resource with a guaranteed teardown path.
- Do not add PacketLogger, captured Bluetooth traffic, proprietary icons, credentials, or generated
  App/PKG artifacts to the repository.
- Update `SOURCE_PROVENANCE.md` when code is copied or substantially adapted from another project.
- Preserve the notices in `LICENSE`, `NOTICE`, and the component-specific license files.
