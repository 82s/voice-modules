# Voice Modules & Audio Hub Suite

Complete audio engineering toolkit for Discord, VB-Audio Matrix, and Ableton Live.

---

## 🎛️ 1. Audio Hub -- VB-Audio Matrix & Ableton Live Toolkit (`/AudioHub`)

A security-hardened launcher, endpoint manager, preset deployer, and audio engine controller located in [`AudioHub/`](./AudioHub):

- **Interactive Launcher (`audio hub.bat`)**: Launches VB-Audio Matrix and Ableton Live together, restarts the engine on glitch/buffer issues, and integrates volume settings.
- **Manage Audio Endpoints (`Rename VB.bat`)**: Registry scanner to preview, rename, enable, and restore VB-Audio Matrix virtual audio pins with rollback protection.
- **Matrix Presets (`AudioHub/VBM`)**: Ready-to-load XML total configurations (`Everything 32 track.xml`, `Routing 32 track.xml`, 8-track setups, and MIDI mappings).
- **Project Templates (`AudioHub/templates`)**: Pre-configured Ableton Live project templates (`Template.als`, `Shifter Set.als`).
- **Full Documentation**: Check out [`AudioHub/README.md`](./AudioHub/README.md) for complete setup instructions.

---

## 🎙️ 2. Discord Voice Modules & Tools

Zero-compiler drop-in stereo audio modules and real-time C++ patchers for Discord, Discord Canary, PTB, Development, and Vencord:

### Instant Module Swapper
- Located in `AudioHub/Swap Discord Module.bat` (and Option 8 in `audio hub.bat`).
- Pre-compiled high-bitrate & gain profiles:
  - `[1x Gain]` -- Clean studio stereo
  - `[2x Gain]` -- Boosted mic input
  - `[5x Gain]` -- Medium gain boost
  - `[10x Gain]` -- Max gain boost
  - `248k` -- High bitrate voice
- Safe 1-click restore back to vanilla Discord.

### Standalone Patchers & Scripts (Repo Root)
- **`Good Mic.bat`**: Downloads and runs the latest live voice node patcher.
- **`Okay mic.bat`**: Quick stereo installer script.
- **`Discord_voice_node_patcher.ps1`**: Standalone PowerShell patcher for compiling custom offsets.
- **`DiscordVoiceFixer.ps1`**: Automated Discord voice subsystem fixer and repair script.
- **`Updates/` & `Discord Voice Backup/`**: Verified unpatched and patched node builds for Windows & Linux.
