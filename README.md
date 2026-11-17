# RIISE GenUI POC: emulator setup

Everything needed to run the RIISE GenUI proof of concept (the "AI" view inside the UAT app) on an
Android emulator on your own laptop, Mac or Windows.

**Private and local-only.** This repo holds only the POC overlay (one new Flutter package, a
six-line host patch, one manifest overlay) and setup scripts. It does **not** contain the RIISE
app source: you get that from the company CodeCommit repo with your own access. Do not make this
repo public, and do not commit or push the overlay into the company repo.

## Which path?

| | Path A: prebuilt APK | Path B: build from source |
|---|---|---|
| Use it to | see the POC working | read, change and rebuild the code |
| Needs | Android Studio | Android Studio, Flutter 3.44.4, JDK 17, company repo access |
| Time | about 15 minutes | about an hour the first time |

Both paths need the laptop to be on a network that the UAT API gateway allows (office network or
Netskope active). On any other network the app installs but login fails with "Oops, something went
wrong". Quick check in the laptop's browser: `https://api.dev.riseapp.in/userlogin/api/Login/IdentifyUser`
should say "Not Found" (allowed). An "explicit deny" message means the network is blocked.

Log in with your own UAT client code. Orders placed from the AI view are real UAT orders.

## Common setup (both paths)

1. Install [Android Studio](https://developer.android.com/studio). In **SDK Manager > SDK Tools**
   tick **Android SDK Command-line Tools (latest)**.
2. Clone this repo (`gh repo clone MO-Siddhant-44490/riise-genui-poc-emulator`) and open a terminal in it.
3. Create and start the emulator (Pixel 7, Android 13):

   | Mac (Terminal) | Windows (PowerShell) |
   |---|---|
   | `bash scripts/mac/01_create_emulator.sh` | `.\scripts\windows\01_create_emulator.ps1` |
   | `bash scripts/mac/02_start_emulator.sh` | `.\scripts\windows\02_start_emulator.ps1` |

   On Windows, if scripts are blocked, run once: `Set-ExecutionPolicy -Scope Process Bypass`.

## Path A: install the prebuilt APK

The APK is attached to this repo's [latest release](../../releases/latest). With the GitHub CLI
logged in (`gh auth login`), the script downloads and installs it:

| Mac | Windows |
|---|---|
| `bash scripts/mac/03_install_prebuilt.sh` | `.\scripts\windows\03_install_prebuilt.ps1` |

Or download the APK from the release page and pass its path (`03_install_prebuilt.sh ~/Downloads/x.apk`,
`-Apk C:\...\x.apk`). The AI settings are already inside this build; no `genui.env` is needed.

The app ships ARM libraries only. Apple Silicon Macs run it natively. On Intel/AMD laptops the
Android 13 `google_apis` image runs it through ARM translation, which is slower.

## Path B: build from source

1. Install Flutter **3.44.4** and JDK 17, and clone the company repo (`mosl-riseapp-repo` on
   CodeCommit), branch `develop/sprint_18_release`. The overlay was made on the commit in
   [`BASE_COMMIT`](BASE_COMMIT).
2. Copy `genui.env.example` to `genui.env` and fill in the two values sent to you privately
   (never commit this file; it is git-ignored).
3. Apply the overlay, then build and install:

   | Mac | Windows |
   |---|---|
   | `bash scripts/mac/04_apply_overlay.sh <company-repo>` | `.\scripts\windows\04_apply_overlay.ps1 -Repo <company-repo>` |
   | `bash scripts/mac/05_build_install.sh <company-repo>` | `.\scripts\windows\05_build_install.ps1 -Repo <company-repo>` |

4. To take every POC change back out of the company repo: `99_remove_overlay` (same arguments).

What the overlay changes in the company checkout (all marked `GENUI-POC (local only)`):

- `packages/mo_genui/` (new): the whole POC.
- `apps/super_app/pubspec.yaml`: adds the package (2 lines).
- `.../landing_page_header/landingpage_header.dart`: adds the AI entry button (4 lines).
- `apps/super_app/android/app/src/uat/AndroidManifest.xml` (new): drops the SMS-read permissions
  from UAT test builds.

## Using it

Log in, then tap the **AI** pill in the home header. Things to try: "aaj mera portfolio kyu gira",
"Reliance ka chart dikhao", "Infosys vs TCS kaun better", "HDFC buy", "what if the market crashes
8 percent", "create a board called Morning". [`docs/QUERY_MAP.md`](docs/QUERY_MAP.md) lists which
component and API each kind of question maps to.

## Troubleshooting

- **Login hangs or "Oops, something went wrong"**: network. Run the browser check above. If the
  laptop changed network after the emulator started, run `02_start_emulator` again (the emulator
  keeps its old DNS servers).
- **AI view answers "unsupported" for everything, or shows keyword routing**: Path B build made
  without a valid `genui.env`.
- **`host.patch` does not apply**: your checkout is far from the base commit. Make the two small
  edits by hand; they are listed in `overlay/host.patch`.
- **Gradle cannot resolve a dependency (private feed)**: this is the normal app build, not the POC.
  Build the plain app the way your team usually does first, then re-run `05_build_install` (add
  `OFFLINE=1` on Mac or `-Offline` on Windows to reuse the Gradle cache).
- **Charts and live prices are blank**: the UAT live price feed is down; REST-backed cards still work.
- **`INSTALL_FAILED_UPDATE_INCOMPATIBLE`**: another UAT build signed with a different key is on the
  emulator. `adb uninstall com.mosl.mobile.uat`, then install again.

## How it works (short)

Question → `RouterClient` sends the catalog-generated prompt to the router service (a small AWS
Lambda that calls Bedrock; source in [`router_service/`](router_service), already deployed, nothing
to deploy) → the model returns one catalog action with parameters → `GenUiCatalog` renders that
card → the card loads data through the app's existing repositories with the logged-in session.
The model never sees account data and never produces numbers. Start reading at
`overlay/packages/mo_genui/lib/src/catalog/catalog.dart` and `.../router/router_client.dart`.

## Status of these scripts

The Mac scripts were run on an Apple Silicon Mac. The Windows scripts are direct ports and have
not been run on a Windows machine yet; please report anything that fails.
