# Hermes Agent Portable（Windows x64）

[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) 的免安裝版。解壓後即可執行，所有依賴都內建，也適合有防火牆、Proxy、Nexus 套件庫的企業環境。

- **全部內建**：Git Bash（PortableGit）、Python 3.14、Node.js 26 / npm、uv、Chromium、ripgrep、FFmpeg、Hermes Desktop。不需要預先安裝任何東西，也不需要系統管理員權限。
- **兩種介面**：`Hermes-TUI.cmd`（終端介面）與 `Hermes-Desktop.cmd`（Electron 桌面版）；`Hermes-Shell.cmd` 開啟已套用 Portable 環境的 Git Bash。終端機一律使用內建的 Git Bash。
- **環境隔離**：不繼承 Windows 的環境變數（API Key、`PYTHONPATH`、`NODE_OPTIONS`、Proxy…），也不讀使用者的 `.npmrc`、`.gitconfig`、`pip.ini`。Portable 專用的設定集中在 `config\portable.env`，所有資料都在資料夾內的 `data\`。
- **Nexus 套件來源**：PyPI 與 npm 分別設定。`uv.lock` 與 `package-lock.json` 的下載網址可以手動切換到 Nexus，名稱、版本、雜湊不變。發行版與建置流程都支援，未設定時使用原始來源。
- **企業網路**：支援 HTTP(S) Proxy、Windows 憑證存放區、自訂 CA，以及最後手段的不驗證 TLS。
- **停用 cua-driver**：不打包、不下載，電腦操作工具組已停用。
- **可自行建置**：GitHub Actions 與本機（包括公司內網、Nexus、封閉網路）使用同一支建置腳本。上游作為 git submodule 引用（固定在穩定版 tag），沿用上游的打包管線，加上少量 patch。

## 下載與快速開始

1. 從 Releases 下載 `Hermes-Portable-<版本>-win-x64.zip`，按右鍵 →「內容」→ 勾選「解除封鎖」。
2. 解壓到短路徑，例如 `C:\HP\`。
3. 執行 `Hermes-TUI.cmd` 或 `Hermes-Desktop.cmd`，依引導設定模型供應商與 API Key。
4. 企業網路：把 `config\portable.env.example` 複製成 `config\portable.env`，設定 Proxy、Nexus 與憑證，然後在 `Hermes-Shell.cmd` 中執行：
   `hermes-portable sources pypi use-nexus`、`hermes-portable sources npm use-nexus`、`hermes-portable doctor`

## 文件

- [安裝與使用](docs/INSTALL.md)：系統需求、解壓、啟動、首次設定、升級、移除、常見問題
- [設定說明](docs/CONFIGURATION.md)：`portable.env` 全部欄位、環境隔離、Nexus 來源切換、Proxy、憑證、強制設定
- [自行建置](docs/BUILD.md)：在自己的電腦或公司內部建出 Portable 壓縮檔：環境需求、系統設定、Proxy／Nexus／封閉網路、疑難排解
- [維護文件](docs/MAINTENANCE.md)：架構、CI、Nexus 模式建置、升級上游、更新 patch、發版、疑難排解
- [第三方授權](docs/THIRD-PARTY-NOTICES.md)

## 專案結構

```
upstream/   上游 Hermes Agent（git submodule）
patches/    對上游的最小修改
build/      建置腳本（Git Bash）、設定與測試
portable/   進入壓縮檔的 Portable 層（啟動檔、環境腳本、hermes-portable、來源切換）
docs/       文件
```

建置：`bash build/build.sh all`（詳見 [自行建置](docs/BUILD.md)）。
