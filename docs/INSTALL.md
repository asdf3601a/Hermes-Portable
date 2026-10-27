# Hermes Portable 安裝與使用

本文件給使用者與 IT 人員：如何取得、解壓、啟動 Hermes Portable，以及在企業網路（Nexus、Proxy、自簽憑證）中完成第一次設定。設定項目的完整說明見 [CONFIGURATION.md](CONFIGURATION.md)。

## 1. 系統需求

| 項目 | 需求 |
|---|---|
| 作業系統 | Windows 10 / 11，x64 |
| 磁碟 | 本機 NTFS 磁碟。解壓後約數 GB，加上對話資料與快取，建議預留 8 GB 以上 |
| 權限 | 一般使用者即可，**不需要**系統管理員權限 |
| 預先安裝 | **不需要** Python、Node.js、Git、瀏覽器。全部內建於壓縮檔 |

內建元件：Git for Windows（PortableGit，提供 Git Bash）、Python 3.14、Node.js 26 / npm、uv、Chromium（Chrome for Testing）、ripgrep、FFmpeg、Hermes Desktop（Electron）。不含 cua-driver（電腦操作功能已停用）。

## 2. 下載與解壓

1. 從 GitHub Releases 下載 `Hermes-Portable-<版本>-win-x64.zip` 與同名的 `.sha256`。
2. （建議）核對雜湊值。在命令提示字元執行：
   `certutil -hashfile Hermes-Portable-<版本>-win-x64.zip SHA256`，結果應與 `.sha256` 檔案內容相同。
3. **解除封鎖**：對 zip 按右鍵 → 內容 → 勾選「解除封鎖」→ 確定。這樣解壓出來的檔案就不會帶「來自網際網路」的標記，可以避免 SmartScreen 反覆警告，也能減少防毒軟體逐一掃描造成的啟動延遲。
4. **解壓到短路徑**，例如 `C:\HP\` 或 `D:\Tools\HP\`。
   - 壓縮檔內的路徑很深，放在很長的路徑下（例如桌面或「下載」裡的多層資料夾）可能超過 Windows 260 字元的路徑限制而解壓失敗。
   - 建議使用 7-Zip 解壓。Windows 檔案總管內建的解壓也可以，但較慢，碰到長路徑時也較容易失敗。
   - 不要解壓到網路磁碟（UNC 路徑）、OneDrive 同步資料夾或 exFAT/FAT32 格式的隨身碟。

解壓後的結構：

```
C:\HP\HermesP-<版本>\
├─ Hermes-TUI.cmd         啟動 Hermes 終端介面（TUI）
├─ Hermes-Desktop.cmd     啟動 Hermes Desktop（桌面視窗）
├─ Hermes-Shell.cmd       開啟內建 Git Bash（已套用 Portable 環境）
├─ config\                設定檔（portable.env.example → 複製成 portable.env）
├─ desktop\               Hermes Desktop 與其內的 Hermes Agent、Python、Node、Git Bash 等
├─ portable\              Portable 啟動腳本與工具（請勿修改）
├─ docs\                  文件
├─ licenses\              第三方授權
├─ VERSION.txt            版本與元件清單
└─ data\                  第一次啟動時建立：對話、設定、快取都在這裡
```

整個資料夾可以搬移或改名。所有狀態都存在 `data\`，設計上不會寫入這個資料夾以外的位置。

## 3. 啟動

| 啟動檔 | 用途 |
|---|---|
| `Hermes-TUI.cmd` | 在主控台視窗中開啟內建 Git Bash，並自動執行 `hermes --tui`。離開 TUI 後會留在 Git Bash 提示字元，可輸入 `hermes`、`hermes --tui` 再次啟動，或輸入 `exit` 關閉視窗 |
| `Hermes-Desktop.cmd` | 啟動 Hermes Desktop 桌面視窗。環境由隱藏的 Git Bash 準備，啟動紀錄在 `data\logs\desktop-launcher.log`。關閉最後一個 Desktop 視窗後，背景的 Hermes gateway 也會一併停止 |
| `Hermes-Shell.cmd` | 開啟內建 Git Bash（Portable 環境），可使用 `hermes`、`hermes-portable`、`npx`、`uvx`、`git` 等指令 |
| `Hermes-Shell.cmd 指令 參數…` | 不開互動視窗，直接在 Portable 環境執行一個指令並回傳結束代碼，適合寫腳本，例如 `Hermes-Shell.cmd hermes-portable doctor` |

說明：

- 終端機一律使用**內建的 Git Bash**。Hermes 的 TUI 與 CLI 需要真正的 Windows 主控台，所以 Git Bash 執行在 .cmd 開出的主控台視窗中，不使用 Git 附帶的 mintty 視窗。Windows 11 預設會用 Windows Terminal 開啟這個視窗。
- Hermes Agent 執行指令時用的 shell，以及 Desktop 內建的終端機面板，也都是同一套內建 Git Bash。
- 主控台的起始目錄預設是你的 Windows 使用者資料夾，可用 `HP_START_DIR` 修改。從其他終端機在某個資料夾內執行 .cmd 時，則以當時所在的資料夾為起始目錄。

## 4. 第一次設定

1. 開啟 `Hermes-TUI.cmd`（或 Desktop）。第一次使用時，Hermes 會引導你選擇模型供應商、填入 API Key。設定存在 `data\hermes\`（`config.yaml`、`.env`）。
2. API Key 也可以事先放在下列任一處：
   - `data\hermes\.env`（Hermes 自己的設定檔，例如 `OPENAI_API_KEY=...`）
   - `config\portable.env`（Portable 層的環境變數，見 [CONFIGURATION.md](CONFIGURATION.md)）
3. Windows 系統或使用者帳號裡設定的環境變數（例如全域的 `OPENAI_API_KEY`、`HTTP_PROXY`、`PYTHONPATH`）**不會**傳進 Hermes。這是刻意的設計。如果確實要沿用某個變數，請在 `config\portable.env` 中用 `HP_ENV_PASSTHROUGH` 列出它。

## 5. 企業網路設定（Nexus／Proxy／憑證）

1. 把 `config\portable.env.example` 複製成 `config\portable.env`，用記事本編輯。常見設定：

   ```ini
   HP_PYPI_INDEX_URL=https://nexus.example.com/repository/pypi-proxy/simple
   HP_NPM_REGISTRY=https://nexus.example.com/repository/npm-proxy/
   HP_HTTPS_PROXY=http://proxy.example.com:8080
   HP_HTTP_PROXY=http://proxy.example.com:8080
   HP_NO_PROXY=.example.com
   ```

2. **憑證**：如果公司的 Proxy 會解密 HTTPS（MITM），建議把公司根憑證匯入「目前使用者」的憑證存放區。這個動作不需要系統管理員權限：
   `certutil -user -addstore Root C:\path\corp-root-ca.cer`
   Portable 預設使用 Windows 憑證存放區（`HP_SSL_USE_SYSTEM_STORE=1`），匯入後 uv、Node/npm、Git、Python、Desktop 都會信任它。無法匯入時，改用 `HP_SSL_CA_FILE` 指向 PEM 檔。`HP_SSL_INSECURE=1`（完全不驗證憑證）只能當最後手段。
3. 開啟 `Hermes-Shell.cmd`，把套件鎖定檔切換到 Nexus（只需要做一次）：

   ```bash
   hermes-portable sources pypi use-nexus     # uv.lock 改由 Nexus 下載
   hermes-portable sources npm use-nexus      # package-lock.json 改由 Nexus 下載
   hermes-portable sources verify             # 確認套件、版本、雜湊與原始鎖定檔完全一致
   hermes-portable doctor                     # 檢查工具、設定、鎖定檔來源與網路連線
   ```

   切換時只改下載網址，套件名稱、版本與雜湊都不變，所以不需要重建 Python 環境。要改回原始來源，執行 `hermes-portable sources pypi use-original` 與 `hermes-portable sources npm use-original`。詳細原理見 [CONFIGURATION.md](CONFIGURATION.md#4-套件來源切換nexus)。

## 6. 升級

1. 把新版 zip 解壓到**新的資料夾**（例如 `C:\HP\HermesP-0.22.6-p1\`）。
2. 從舊資料夾複製 `data\` 與 `config\portable.env` 到新資料夾。
3. 如果舊版有切換到 Nexus，請在新版重新執行 `hermes-portable sources pypi use-nexus` 與 `npm use-nexus`。鎖定檔隨每個版本更新，切換狀態不會跟著 `data\` 帶過去。
4. 確認新版正常後，刪除舊資料夾。

`hermes update` 在 Portable 版中已停用，更新一律透過新版的 Portable 壓縮檔。

## 7. 移除

確認 Hermes 已全部關閉（`Hermes-Shell.cmd hermes-portable stop` 會停止背景 gateway），然後直接刪除整個資料夾即可。

## 8. 常見問題

**SmartScreen 擋住 .cmd 或 .exe**
請先依第 2 節對 zip「解除封鎖」再解壓。已解壓的檔案可以在檔案內容中逐一解除封鎖，或刪除後重新解壓。

**防毒軟體把 `uv.exe` 等檔案判定為惡意程式**
這是常見的誤判（未簽章的 Rust 程式會下載並安裝套件）。請 IT 將 Portable 資料夾加入例外清單，或回報誤判。

**TUI 一閃而過或顯示 `no TTY`**
TUI 必須在主控台視窗中執行。請使用 `Hermes-TUI.cmd`，不要從 mintty（`git-bash.exe`）或其他沒有主控台的環境執行。

**Desktop 沒有出現**
查看 `data\logs\desktop-launcher.log` 與 `data\hermes\logs\desktop.log`。也可以在 `Hermes-Shell.cmd` 中執行 `hermes-portable doctor`。

**解壓失敗、出現路徑太長的錯誤**
請解壓到更短的路徑，例如 `C:\HP\`，並改用 7-Zip。

**搬移資料夾後變慢或占用變大**
Hermes 依安裝路徑記錄部分狀態，搬移後舊狀態就用不到了。執行 `hermes-portable doctor --prune` 可以列出用不到的狀態，加上 `--yes` 會刪除它們。

**套件下載失敗（企業網路）**
執行 `hermes-portable doctor`。它會顯示鎖定檔目前的下載來源，以及設定與鎖定檔不一致之處（例如已設定 Nexus 卻還沒執行 `sources ... use-nexus`），並透過目前的 Proxy/憑證設定測試能否連到 Nexus。
