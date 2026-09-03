# Project operating rules

These rules are non-negotiable for every local macOS App build and test deployment.

1. The only App used for live testing is `/Applications/SiriRemote.app`.
2. After compiling and packaging a user-test build, install that verified bundle at
   `/Applications/SiriRemote.app`. Never launch a project-local bundle as the live App.
3. Preserve the existing stable `Developer ID Application: ZIAN XI (96M7FW2XLU)` identity. Verify
   the packaged bundle's signature before replacing the installed App.
4. Never silently fall back to ad-hoc signing for a local development build. If the stable identity
   is unavailable or signature verification fails, stop before installation or restart and tell the
   user.
5. Restart only after installation and signature verification, then confirm the single running UI
   process executes `/Applications/SiriRemote.app/Contents/MacOS/SiriRemote`.
6. Treat SiriRemote as an always-on App. Unless the user explicitly asks to stop it, finish every
   local App build, installation, configuration change that needs a reload, or user-test handoff by
   ensuring `/Applications/SiriRemote.app` is running as exactly one UI process. Do this
   automatically; never wait for the user to ask for the App to be started.

Public release artifacts may use their explicitly requested release signing workflow, but must not
be substituted for the stable-signed local development App.
