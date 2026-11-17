# Instructions for Claude: set up the RIISE GenUI POC emulator on this laptop

The person asking you is a Motilal Oswal colleague who wants to see the RIISE GenUI proof of
concept running on an Android emulator. Your job: get the emulator created, the app installed and
launched, then hand over at the login screen. Default to **Path B (build from the codebase)**.
Use Path A (prebuilt APK) only if they ask for the quick route or the source build is blocked.

## Rules (do not break these)

- This repo is private. Never make it public, never copy its contents or the APK to another service.
- Ask before installing any software. If an install is blocked by company policy, stop and tell
  the person to request it from IT; do not look for workarounds.
- Never type a client code, PAN, mPIN or OTP into the app. The person logs in by hand.
- Never print, log or commit `genui.env` or its values. Never commit `*.apk`.
- Path B only: the overlay is local-only. Never commit or push anything in the company repo, and
  restore the root `pubspec.lock` after `flutter pub get` (the scripts do this).
- Do not deploy or change anything in AWS. `router_service/` is reference only; it is already deployed.
- Orders placed from the app are real UAT orders. Do not place any.

## Path A, step by step (quick route; steps 1 to 5 are shared with Path B)

Run from the repo root. Mac uses `bash scripts/mac/<name>.sh`; Windows uses
`.\scripts\windows\<name>.ps1` in PowerShell (if scripts are blocked:
`Set-ExecutionPolicy -Scope Process Bypass`).

1. **Network check first.** Fetch `https://api.dev.riseapp.in/userlogin/api/Login/IdentifyUser`
   from the laptop (curl). A body of "Not Found" means the network is allowed. A message containing
   "explicit deny" means it is not: tell the person to connect to the office network or turn on
   Netskope, and continue only with the install (login will not work until that is fixed).
2. **Prerequisites.** If Android Studio's SDK (with command-line tools) is already installed, skip
   this. Otherwise, after the person agrees, run `00_install_prereqs`. It installs JDK 17, the
   Android command-line tools and the GitHub CLI; Android Studio itself is not needed.
   On Windows open a new PowerShell window afterwards.
3. **GitHub login.** `gh auth status`. If not logged in, ask the person to run `gh auth login`
   themselves (it is interactive).
4. **Create the emulator:** `01_create_emulator` (downloads the Android 13 image, about 1.5 GB).
5. **Start it:** `02_start_emulator`. It prints whether the UAT hosts resolve from the emulator.
6. **Install and launch the app:** `03_install_prebuilt` (downloads the APK from this repo's
   latest release, about 200 MB). Expect `Success`.
7. **Verify.** Take a screenshot (`adb exec-out screencap -p > screen.png`) and look at it. You
   should see the RIISE login screen ("LOGIN OR SIGNUP"). Tell the person to: tap "Login Via Client
   ID", log in with their own UAT client, then tap the **AI** pill in the home header and try
   "HDFC Bank ke peers kaun hai".

## If something fails

- `sdkmanager` not found: prerequisites step was skipped, or on Windows the window was not reopened.
- Emulator will not start on Windows: "Windows Hypervisor Platform" is off (needs admin and a
  restart), or virtualization is disabled in BIOS. Tell the person; do not change BIOS settings.
- `03_install_prebuilt` says the image cannot run ARM apps: the AVD was not created by
  `01_create_emulator`; delete it (`avdmanager delete avd -n RIISE_API_33`) and re-run step 4.
- `gh release download` fails with "not found": the person has not accepted the repo invitation.
- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: `adb uninstall com.mosl.mobile.uat`, then step 6 again.
- App shows "Oops, something went wrong" at login, or login hangs: network. Redo step 1; if the
  laptop changed network since the emulator started, re-run `02_start_emulator`.
- The Windows scripts were ported from the Mac ones and not yet run on Windows. If one has a small
  bug, fix it locally, tell the person what you changed, and carry on.

## Path B, step by step (default)

Do steps 1 to 5 of Path A first (network check, prerequisites, GitHub login, create and start the
emulator). Then:

1. **Flutter 3.44.4 and JDK 17.** Check `flutter --version`. If Flutter is missing or a different
   version, ask before installing; prefer the version manager the person already uses (fvm), or
   the official archive for 3.44.4. Do not change a Flutter install they use for other work
   without asking.
2. **Company repo.** Ask where their checkout of the RIISE repo is (CodeCommit
   `mosl-riseapp-repo`). If they have none, they clone it with their own AWS access; you cannot
   do that for them. It should be on branch `develop/sprint_18_release`, at or near the commit in
   `BASE_COMMIT`. Check `git status` there first: if they have uncommitted work, stop and ask.
3. **Settings file.** `genui.env` must exist in this repo's root with `GENUI_AI_URL` and
   `GENUI_AI_TOKEN` filled in (template: `genui.env.example`). The repo owner sends it privately.
   Check that it exists and that both keys are non-empty without printing the values.
4. **Apply the overlay:** `04_apply_overlay <company-repo>` (Windows: `-Repo <company-repo>`).
   Expect exactly two modified files, one new manifest and the new `packages/mo_genui/` in
   `git status`.
5. **Build and install:** `05_build_install <company-repo>`. First build takes 10 to 20 minutes
   and produces a debug APK of about 380 MB, then installs and launches it.
6. **Verify** as in Path A step 7. In the AI view the line under each answer should say
   `service · qwen3-32b...`; if it says keyword routing, `genui.env` was empty at build time.

If the build fails:

- **Gradle cannot resolve a dependency from a private feed (eMudhra):** this is the host app's
  normal build requirement, not the POC. Ask the person how their team builds the UAT app on a
  new machine and follow that; once one normal build has succeeded, re-run step 5 (optionally
  with `OFFLINE=1` / `-Offline`). Do not copy credentials out of build files into chat or logs.
- **`host.patch` does not apply:** the checkout is far from the base commit. Make the two edits by
  hand; `overlay/host.patch` shows them (one dependency in `apps/super_app/pubspec.yaml`, one
  import and one button in `landingpage_header.dart`).
- **Dart compile errors inside `packages/mo_genui`:** the app's internal APIs moved since the base
  commit. Report the errors to the person; check out the base commit in a separate worktree if
  they agree.

`99_remove_overlay <company-repo>` takes every POC change back out. More detail in `README.md`.
