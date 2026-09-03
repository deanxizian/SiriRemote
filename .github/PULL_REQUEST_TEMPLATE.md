## Summary

Describe the user-visible change and why it belongs in SiriRemote's intentionally narrow scope.

## Verification

- [ ] `swift test --package-path SiriRemoteCore`
- [ ] `(cd app && ./build.sh && ./SiriRemote --verify-config)`
- [ ] Relevant microphone/component tests, when changed
- [ ] A2854 hardware behavior tested, when changed
- [ ] Documentation and `SOURCE_PROVENANCE.md` updated, when needed
- [ ] No generated App/PKG, capture, credential, or unrelated project files added
