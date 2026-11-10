# Audio Hub -- Security-Hardened Launcher & VB-Audio Matrix Toolkit

Universal launcher, endpoint manager, preset deployer, and audio engine controller for **VB-Audio Matrix** and **Ableton Live**.

---

## Sending to Collaborators & Friends

Two ready-to-share ZIP packages are built in this directory:

| Package | Size | Best For | What's Included |
|---------|------|----------|-----------------|
| **`AudioHub_v2026.zip`** | ~33 MB | Fast sharing via Discord, email, or Slack | All scripts, batch launchers (`audio hub.bat`, `Rename VB.bat`, `Swap Discord Module.bat`, `Patch Discord.bat`, `Unblock.bat`), documentation, `VBM\` presets (`Everything 32 track.xml`, `Routing 32 track.xml`), and the pre-compiled `modules\` suite (`[1x Gain]`, `[2x Gain]`, `[5x Gain]`, `[10x Gain]`, `248k`). Automatically downloads and verifies the official VB-Audio installer when Option 5 is selected. |
| **`AudioHub_v2026_Full.zip`** | ~66 MB | Google Drive, Mega, USB drives, or offline installs | Everything in `AudioHub_v2026.zip` **plus** the verified offline installer archive (`things\VBAudioMatrix_Setup_v2026.zip`). 100% offline, zero internet downloads required. |

### Collaborator Setup Instructions (Step-by-Step)

1. **Extract**: Unzip the folder to any location (e.g. `C:\AudioHub` or `Documents`).
2. **If Windows SmartScreen or ExecutionPolicy appears**:
   - Double-click **`Unblock.bat`** (or right-click `AudioHub_v2026.zip` -> Properties -> check **Unblock** -> Apply before extracting).
3. **Install VB-Audio Matrix** (if not already installed):
   - Double-click **`audio hub.bat`** -> choose **Option 5**.
   - If using `AudioHub_v2026_Full.zip`, it uses the bundled offline installer instantly. Otherwise, it downloads from `download.vb-audio.com` and verifies Authenticode + SHA-256 hash.
   - Run the installer to completion.
   - **CRITICAL**: **Restart your PC** after installing VB-Audio Matrix! Windows requires a reboot for virtual audio drivers to register in the Windows audio subsystem.
4. **Rename & Configure Audio Endpoints**:
   - Double-click **`Rename VB.bat`** (or Option 6 in `audio hub.bat`).
   - Press **`A`** to Apply renames (e.g. Desktop Audio, Voicechat, Media, Browser).
   - Confirm UAC prompt.
   - Type **`Y`** to restart the Windows Audio service.
   - **Note**: If Sound Control Panel (`mmsys.cpl`) is already open, close and reopen it so Windows refreshes the cached names.
5. **Deploy & Load Matrix Presets**:
   - In **`audio hub.bat`**, choose **Option 7** (`VB-Audio Matrix Presets`).
   - This copies `Everything 32 track.xml` and `Routing 32 track.xml` into the folder.
   - Open **VB-Audio Matrix**:
     * **Step 5a (Total Configuration)**: In the Matrix top menu, click **"Load Total Configuration..."** -> select **`Everything 32 track.xml`**. This turns ON Virtual ASIO 32, turns ON Matrix VAIO 1 to 5, sets the master clock, and applies the complete routing grid!
     * **Step 5b (Grid Routing Only)**: To reload cross-points later, click **"Load Grid / Routing Settings..."** -> select **`Routing 32 track.xml`**.
6. **Discord Stereo & High-Bitrate Voice (Optional)**:
   - Double-click **`Swap Discord Module.bat`** (or Option 8 in `audio hub.bat`).
   - Select your preferred pre-compiled profile (e.g. `[1x Gain]` for clean studio stereo, `[2x Gain]` for boosted mic input).
   - Zero compiler, zero Visual Studio, and zero admin rights required! Automatically creates an original stock backup on first use.
   - To revert to vanilla Discord anytime, choose `[R] Restore Stock Vanilla Voice`.
7. **Launch Rig**:
   - In `audio hub.bat`, choose **Option 1** to start both VB-Audio Matrix and Ableton Live together!

---

## Menu Options

| # | Option | Description |
|---|--------|-------------|
| 1 | **Launch Live Audio Hub** | Starts VB-Audio Matrix and Ableton Live. Automatically finds adjacent `.als` project files across project directories. Verifies executables are local files. If Ableton is patched or modified, `AllowUnverifiedAbleton` permits launching while logging verification status. Optionally boosts CPU priority (defaults to **AboveNormal**, not High). |
| 2 | **Quick-Restart Audio Engine** | Warns before closing Matrix. Attempts graceful close first (`CloseMainWindow`); asks separately before force-closing. Then relaunches via Option 1 to clear latency and buffer glitches. |
| 3 | **Windows Volume Mixer & Settings** | Opens `ms-settings:sound` and `ms-settings:apps-volume`. Displays per-app routing reference for Matrix VAIOs. |
| 4 | **Diagnostic Check** | Lists registered ASIO drivers and detected audio devices (VB-Audio, Focusrite, USB). Read-only -- no admin required. |
| 5 | **Download & Install VB-Audio Matrix** | Secure download and offline installer manager. Checks for local verified installer in `things\` or `installers\` first before downloading. Verifies SHA-256 hash and Authenticode signature (`BUREL VINCENT Entrepreneur individuel`). |
| 6 | **Manage Audio Endpoints** | Opens the Preview / Apply / Restore sub-menu. Scans all 16 VB-Audio Matrix endpoints (8 Render, 8 Capture). |
| 7 | **VB-Audio Matrix Presets** | Deploys authentic presets from `VBM\`: `Everything 32 track.xml` (Total Configuration with devices, VAIO slots online, clock, and grid) and `Routing 32 track.xml` (49-point cross-point routing grid). Provides exact menu instructions for loading in VB-Audio Matrix. |
| 8 | **Discord Voice Tools** | Comprehensive Discord audio suite: **(1) Instant Module Swapper** (zero-compiler required: drop in pre-compiled stereo & high-gain modules `[1x Gain]`, `[2x Gain]`, `[5x Gain]`, `[10x Gain]`, `248k` with 1-click safe revert to stock), **(2) Live Voice Patcher** (advanced C++ compiler for custom patch offsets & features), and **(3) Restore Stock Vanilla Voice**. Also directly accessible via `Swap Discord Module.bat` and `Patch Discord.bat`. |
| 9 | **Exit** | Closes the launcher. |

---

## Endpoint Management

Launched from menu Option **6** or directly via **`Rename VB.bat`**.

### Modes

| Mode | Elevation | Description |
|------|-----------|-------------|
| **Preview (`P`)** | None | Scans the registry for VB-Audio Matrix endpoints (`vbmatrix.*_out` / `_in`). Displays every proposed rename, enable, and disable -- no changes are made. If 0 endpoints are found, provides a reboot troubleshooting reminder. |
| **Apply (`A`)** | Admin (UAC prompt or direct if elevated) | Shows preview, then asks for confirmation. Disable operations for pins 6-8 require **separate explicit confirmation**. Elevated Apply **does not trust registry paths or actions from editable JSON**; it re-validates every proposed operation against a fresh live scan of verified Matrix endpoints. Saves a timestamped JSON backup before writing. Each write captures the original SDDL, temporarily takes ownership, adds a minimal `SetValue | QueryValues` rule, writes the value, and **restores the original SDDL in a `finally` block**. Any SDDL restoration failure is explicitly reported and treated as a failure. Prompts to restart Windows Audio service and refresh Sound Control Panel (`mmsys.cpl`). |
| **Restore (`R`)** | Admin (UAC prompt or direct if elevated) | Lists available backup files from `backups\`. You pick one, confirm, and values and original security descriptors (SDDL) are restored. Re-validates all entries against a live scan of verified Matrix endpoints before writing to any key. |

---

## Download Security

All download and install operations go through [`lib/Hub-Download.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-Download.ps1), which enforces:

| Check | Enforcement |
|-------|-------------|
| **Local cache check** | If `things\VBAudioMatrix_Setup_v2026.zip` is present, hashes and uses it directly -- skipping network download. |
| **HTTPS only** | URL scheme must be `https`. |
| **Domain lock** | URL host must exactly match `download.vb-audio.com`. |
| **Redirect safety** | Redirects are followed manually; any redirect to a different domain or to HTTP is blocked. Max 5 redirects. |
| **Unique temp dir** | A GUID-named temp directory is created and cleaned up in a `finally` block. |
| **Exact filenames** | Both the ZIP and installer filenames must match configured values exactly -- no wildcards. |
| **SHA-256 hash** | The ZIP is hashed and compared to `0840CAB829C2A14DA3D79B643E97C9323FAD1E1EDD117EAA581A198B03AEF358`. |
| **Authenticode** | The installer EXE must have `Status = Valid`. |
| **Signer CN** | The signer's Common Name must match `BUREL VINCENT Entrepreneur individuel`. |
| **Fail closed** | Any mismatch in hash, signature, signer, filename, URL, or redirect aborts immediately. |
| **Installer exit code** | If the installer returns a non-zero exit code, reports failure and exits with code 10. |

---

## Backup and Log Locations

| What | Path |
|------|------|
| Timestamped logs | `logs\<Component>_<timestamp>.log` |
| Endpoint backups | `backups\endpoint_backup_<timestamp>.json` |
| Apply plan files | `backups\endpoint_plan_<timestamp>.json` |
| Matrix XML presets | `VBM\` and root directory |

---

## Verification & Static Analysis

All scripts are strictly verified with **Windows PowerShell 5.1** (`powershell.exe`) and report **0 parser errors**:
- [`lib/Hub-Common.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-Common.ps1) (errors = 0)
- [`lib/Hub-Download.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-Download.ps1) (errors = 0)
- [`lib/Hub-Endpoints.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-Endpoints.ps1) (errors = 0)
- [`lib/Hub-Launch.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-Launch.ps1) (errors = 0)
- [`lib/Hub-DiscordModules.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Hub-DiscordModules.ps1) (errors = 0)
- [`lib/Discord_voice_node_patcher.ps1`](file:///C:/Users/Harper/Documents/%23%23%20Vb%20Stuff/lib/Discord_voice_node_patcher.ps1) (errors = 0)
