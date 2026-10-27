# 第三方元件與授權（Third-party notices）

Hermes Portable 重新散布下列元件。版本以發行檔中的 `VERSION.txt`（`tool.*`）為準；下表為 upstream v0.22.5 所固定的版本（`upstream/pm/lock.json`）。各元件的授權檔收錄於 `licenses/`。

| 元件 | 版本 | 授權 | 來源 / 原始碼 |
|---|---|---|---|
| Hermes Agent（Nous Research） | 0.22.5 | MIT | https://github.com/NousResearch/hermes-agent |
| Hermes Desktop（Electron 應用程式，含 Chromium） | 同上 | MIT；Electron MIT；Chromium 見 `licenses/electron-LICENSES.chromium.html` | https://github.com/electron/electron |
| Git for Windows（PortableGit，含 Git Bash、MSYS2 runtime、mintty、coreutils 等） | 2.53.0.windows.3 | GPL-2.0 與其他（MSYS2 runtime 為 LGPL/GPL） | https://github.com/git-for-windows/git/releases/tag/v2.53.0.windows.3 ；原始碼：https://github.com/git-for-windows |
| Python（python-build-standalone） | 3.14.9+20261021 | PSF License 與其相依元件授權 | https://github.com/astral-sh/python-build-standalone/releases/tag/20261021 |
| Node.js | 26.12.1 | MIT 與其相依元件授權 | https://nodejs.org/dist/v26.12.1/ |
| npm | 12.0.2 | Artistic-2.0 | https://github.com/npm/cli |
| uv | 0.13.5 | MIT 或 Apache-2.0 | https://github.com/astral-sh/uv/releases/tag/0.13.5 |
| ripgrep | 15.2.0 | MIT 或 Unlicense | https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0 |
| FFmpeg（BtbN FFmpeg-Builds，win64 **GPL** 版） | n9.0.1-11-ge47273f4d9 | GPL（GPL 版建置，含 GPL 函式庫） | 二進位：https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-08-31-13-27 ；建置腳本：https://github.com/BtbN/FFmpeg-Builds ；FFmpeg 原始碼：https://git.ffmpeg.org/ffmpeg.git （commit e47273f4d9） |
| Chrome for Testing（Chromium） | 145.0.7632.6 | BSD-3-Clause 與其他 | https://googlechromelabs.github.io/chrome-for-testing/ ；原始碼：https://chromium.googlesource.com/chromium/src |
| Python 套件（Hermes venv） | 見 `desktop/resources/agent-payload/venv/Lib/site-packages/*.dist-info` | 各套件授權 | PyPI |
| npm 套件（Hermes Desktop / TUI / web） | 見 upstream `package-lock.json` | 各套件授權 | npm registry |

依 GPL 要求，上述 GPL 元件的對應原始碼可由表中連結取得；如需書面提供，請聯絡本專案維護者。

Hermes Portable 的建置腳本與 Portable 層（`build/`、`portable/`、`docs/`）不包含上述元件的原始碼修改，唯一的例外是 `patches/` 中對 Hermes Agent（MIT）的修改。
