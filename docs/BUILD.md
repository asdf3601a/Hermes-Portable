# 自行建置 Hermes Portable

在自己的 Windows 電腦（或公司內部的建置機）上，從原始碼建出與 GitHub Release 相同的 `Hermes-Portable-<版本>-win-x64.zip`，不需要 GitHub Actions。

> 目前完整流程只在 GitHub 代管的 Windows runner 上跑通過。本文件的本機步驟是依同一套腳本整理的；如果你在自己的電腦上遇到與本文不符的地方，請回報或直接修正本文件。

GitHub Actions（`.github/workflows/build.yml`）只是依序呼叫 `build/build.sh` 的各個步驟，本機執行的是同一支腳本、同一組設定。架構與各步驟的內部細節見 [MAINTENANCE.md](MAINTENANCE.md) 第 1.1 節。

## 1. 流程概觀

```
bash build/build.sh patch prepare package assemble smoke zip     # 等同 build/build.sh all
```

| 步驟 | 做什麼 | 需要網路 |
|---|---|---|
| `patch` | 把 `upstream/` 重設到 submodule 記錄的 commit、套用 `patches/`；Nexus 模式時切換鎖定檔 | 只用來確認 tag（連不到只會警告） |
| `prepare` | 上游 PM 下載 Python、Node、PortableGit、Chromium 等工具，建立 venv，安裝 npm 依賴 | 是（下載量最大） |
| `package` | 建置前端，以 electron-builder 產生免安裝的 Desktop 資料夾 | 是（Electron 與打包工具） |
| `assemble` | 組出發行資料夾 `HermesP-<版本>/` | 否 |
| `smoke` | 在發行資料夾的副本上跑冒煙測試 | `mirror`／`tls` 組第一次需要 |
| `zip` | 檢查路徑長度，以 7-Zip 壓縮，產生 `.sha256` | 否 |

產物都在 `$HP_BUILD_DIR/dist/`（預設是 repo 裡的 `.build/dist/`）。

## 2. 環境需求

| 項目 | 說明 |
|---|---|
| 作業系統 | Windows 10/11 x64 |
| Git for Windows | 提供 Git Bash；**所有建置指令都在 Git Bash 執行** |
| Python 3.11 以上 | 建議 3.13（CI 使用 3.13）。只用來驅動上游的打包腳本，打包進去的 Python 由建置流程另外下載 |
| 7-Zip | `C:\Program Files\7-Zip\7z.exe`，或 `7z` 在 PATH 中 |
| 磁碟空間 | 約 30 GB（建置目錄、下載快取、發行資料夾與冒煙測試副本） |
| 選用：uv | 只有第 9 節的建置前檢查需要 |

不需要預先安裝 Node.js、npm 或 Electron，建置流程會自己下載固定版本。

找 Python 的順序：`HP_BUILD_PYTHON` → PATH 上的 `python`（3.11 以上）→ `py -3.13`。都找不到時建置會停止並提示。Python 不在 PATH 上時（例如用 uv 安裝的 Python，或 `python` 只是 Microsoft Store 的捷徑），直接指定完整路徑，路徑中用 `/`：

```ini
HP_BUILD_PYTHON=C:/Users/me/AppData/Roaming/uv/python/cpython-3.13-windows-x86_64-none/python.exe
```

> 從 PowerShell 或命令提示字元直接打 `bash`，可能會叫到 WSL 的 `bash.exe`。請從開始選單開啟「Git Bash」，或明確執行 `"C:\Program Files\Git\bin\bash.exe"`。

## 3. 一次性系統設定

CI 在每次建置前都會做這些設定（`build.yml` 的「Keep Defender away from build paths」步驟）。本機只需要做一次。

1. **長路徑**：上游的原始碼和依賴有很深的路徑。

   ```bash
   git config --global core.longpaths true
   ```

   並以系統管理員身分在 PowerShell 啟用 Windows 長路徑支援（需要重新登入才會對所有程式生效）：

   ```powershell
   New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force
   ```

2. **短路徑**：repo 和建置目錄都放在短路徑，例如 repo 在 `C:\hp`、建置目錄 `HP_BUILD_DIR=C:\hpb`。路徑只用英數字，不要有空白。

3. **Defender 例外**：Defender 即時掃描建置目錄會讓建置慢很多，也會造成檔案被鎖住（`WinError 32`）。以系統管理員身分加入例外：

   ```powershell
   Add-MpPreference -ExclusionPath C:\hp, C:\hpb
   ```

   公司電腦通常由 IT 管理 Defender 政策，可能需要請 IT 加入例外。CI 會關閉即時防護，本機不需要也不建議這樣做，只加例外即可。

## 4. 取得原始碼

```bash
git clone --recurse-submodules https://github.com/asdf3601a/Hermes-Portable.git C:/hp
cd C:/hp
```

已經 clone 但 `upstream/` 是空的：`git submodule update --init`。

**連不到 GitHub 的環境**：先把本 repo 和上游 `https://github.com/NousResearch/hermes-agent.git` 鏡像到公司內部的 Git 伺服器，再把 submodule 指向內部鏡像：

```bash
git clone <內部鏡像>/Hermes-Portable.git C:/hp
cd C:/hp
git config submodule.upstream.url <內部鏡像>/hermes-agent.git
git submodule update --init
```

- `.gitmodules` 設定了 `shallow = true`。若內部 Git 伺服器不允許以 SHA 淺層抓取，改用 `git submodule update --init --no-recommend-shallow`。
- 內部鏡像必須包含 `build/bundle.conf` 的 `UPSTREAM_TAG` 所指的 commit。
- `patch` 步驟會向 upstream remote 確認 tag；連不到時只顯示警告，不影響建置。

## 5. 建置設定（`build/build.env`）

```bash
cp build/build.env.example build/build.env
```

`build/build.env` 已列在 `.gitignore`，含帳密的網址放這裡不會被 commit。格式與 `portable.env` 相同（`KEY=VALUE`，可以用記事本編輯，見 [CONFIGURATION.md](CONFIGURATION.md) 第 1 節）。相對路徑以 repo 根目錄為基準。

在一般網路、不用 Nexus 時，什麼都不設也可以建置。常用的設定：

| 設定 | 說明 |
|---|---|
| `HP_BUILD_DIR` | 建置目錄，建議 `C:\hpb`。預設是 repo 裡的 `.build` |
| `HP_BUILD_PYTHON` | 指定 Python，例如 `py -3.13` |
| `HP_HTTP_PROXY`、`HP_HTTPS_PROXY`、`HP_NO_PROXY` | 建置用的 Proxy |
| `HP_SSL_USE_SYSTEM_STORE`、`HP_SSL_CA_FILE`、`HP_SSL_INSECURE` | TLS 憑證（第 7.1 節） |
| `HP_PYPI_INDEX_URL`、`HP_NPM_REGISTRY` | 從 Nexus 建置（第 7.2 節） |
| `HP_PYPI_LOCK_MODE`、`HP_PYPI_FILES_TEMPLATE` | PyPI 鎖定檔的切換方式 |
| `HP_ARTIFACT_MIRROR`、`HP_ELECTRON_MIRROR`、`HP_ELECTRON_BUILDER_BINARIES_MIRROR` | 封閉網路用的二進位檔鏡像（第 7.3 節） |

優先順序：已存在的環境變數 > 設定檔。所以也可以不寫檔案，直接 `HP_BUILD_DIR='C:\hpb' bash build/build.sh all`。

打包內容（版本、排除的工具、大小與路徑門檻）在 `build/bundle.conf`，一般不需要修改，見 [MAINTENANCE.md](MAINTENANCE.md) 第 7 節。

## 6. 執行建置

### 6.1 第一次：分步執行

第一次建議一步一步跑，每一步確認結果後再往下，出問題時就知道停在哪裡。以下假設 `HP_BUILD_DIR=C:\hpb`。

| 指令 | 成功時會看到 |
|---|---|
| `bash build/build.sh patch` | 列出套用的 patch，最後印出 `state.env` 的內容（`UPSTREAM_SHA`、`PATCHED_SHA`、`PORTABLE_VERSION`、`PYPI_SOURCE`、`NPM_SOURCE`） |
| `bash build/build.sh prepare` | 上游 PM 的下載與安裝紀錄，沒有錯誤結束。第一次最久（大量下載），之後會重用快取 |
| `bash build/build.sh package` | `upstream/apps/desktop/release/win-unpacked/` 裡有 `hermes-<7 碼 SHA>.exe` |
| `bash build/build.sh assemble` | `C:\hpb\dist\HermesP-<版本>\` 資料夾，裡面有 `Hermes-TUI.cmd`、`desktop\`、`VERSION.txt` |
| `bash build/build.sh smoke` | 每項 `PASS`（可能有幾個 `WARN`），最後一行 `smoke tests passed` |
| `bash build/build.sh zip` | `Hermes-Portable-<版本>-win-x64.zip`、`.zip.sha256`、`VERSION.txt` |

CI 上的參考時間：快取未命中時 `prepare` 約 12 分鐘。本機視網路與磁碟速度而定，整個流程可能超過一小時。

### 6.2 之後：一次跑完或只跑部分步驟

```bash
bash build/build.sh all
```

步驟一定要依序執行，但可以從中間開始：

| 改了什麼 | 從哪一步重跑 |
|---|---|
| `portable/`、`docs/` | `bash build/build.sh assemble smoke zip` |
| `patches/`、upstream 版本、Nexus 設定（`HP_PYPI_INDEX_URL`、`HP_NPM_REGISTRY`） | `bash build/build.sh all` |
| 只想重新壓縮 | `bash build/build.sh zip` |

### 6.3 快取與清除

- `prepare` 下載的工具與依賴保存在 `$HP_BUILD_DIR/desktop-inputs`（`HP_DESKTOP_CACHE`），每次建置自動重用，並以 sha256 驗證。CI 用上游的 desktop-build-cache action 保存這個目錄，本機不需要。
- Electron 與打包工具的下載在 `$HP_BUILD_DIR/electron-builder`。
- 下載壞掉或想完全重來：刪除整個 `$HP_BUILD_DIR`，再跑 `bash build/build.sh all`。
- 建置後 `git status` 會顯示 `M upstream`：`upstream/` 停在套用 patch 後的本地 commit。這是正常的，不要 commit 它；要還原時執行 `git submodule update upstream`。
- `patch` 會重設 `upstream/` 並清掉裡面未 commit 的修改。不要在 `upstream/` 裡直接改檔；要改上游請改 `patches/`（[MAINTENANCE.md](MAINTENANCE.md) 第 5.3 節）。

## 7. 企業網路

建置使用與 Portable 執行期相同的 `HP_*` 設定名稱，意義見 [CONFIGURATION.md](CONFIGURATION.md)。

### 7.1 Proxy 與公司憑證

```ini
HP_HTTP_PROXY=http://proxy.example.com:8080
HP_HTTPS_PROXY=http://proxy.example.com:8080
HP_NO_PROXY=.example.com
```

公司以 TLS 檢查（SSL inspection）重新簽發憑證時：

- `HP_SSL_USE_SYSTEM_STORE=1`（預設）：信任 Windows 憑證存放區，公司根憑證已由 IT 部署時通常就夠了。
- `HP_SSL_CA_FILE=build/corp-root-ca.pem`：另外指定 PEM 格式的公司根憑證。
- `HP_SSL_INSECURE=1`：不驗證 TLS。只在確認其他方法都無效時暫時使用。

### 7.2 從 Nexus 建置

```ini
HP_PYPI_INDEX_URL=https://nexus.example.com/repository/pypi-proxy/simple
HP_NPM_REGISTRY=https://nexus.example.com/repository/npm-proxy/
```

`patch` 步驟會把上游的 `uv.lock`、`package-lock.json` 的下載網址切換到 Nexus 並 commit，之後所有 Python 與 npm 套件都從 Nexus 下載。先單獨跑一次確認：

```bash
bash build/build.sh patch
```

輸出的 `PYPI_SOURCE`、`NPM_SOURCE` 應該是你的 Nexus 網址（帳密會被去掉）。`HP_PYPI_LOCK_MODE` 預設 `discover`（讀 Nexus 的 simple 頁面），若 Nexus 不允許瀏覽可以改用 `rewrite`。細節見 [MAINTENANCE.md](MAINTENANCE.md) 第 6 節。

### 7.3 完全封閉的網路

除了 PyPI 與 npm，還需要三個 raw proxy：

| Nexus 儲存庫 | 對應設定 |
|---|---|
| PyPI proxy → `https://pypi.org/` | `HP_PYPI_INDEX_URL` |
| npm proxy → `https://registry.npmjs.org/` | `HP_NPM_REGISTRY` |
| raw proxy → `https://hermes-assets.nousresearch.com/` | `HP_ARTIFACT_MIRROR` |
| raw proxy → `https://github.com/electron/electron/releases/download/` | `HP_ELECTRON_MIRROR` |
| raw proxy → `https://github.com/electron-userland/electron-builder-binaries/releases/download/` | `HP_ELECTRON_BUILDER_BINARIES_MIRROR` |

加上第 4 節的內部 Git 鏡像，整個建置就不需要連到外部網路。冒煙測試的 `mirror`、`tls` 組第一次會下載測試用的套件，封閉網路下請略過（第 8 節）。

## 8. 冒煙測試在本機的注意事項

冒煙測試在發行資料夾的副本上執行，不會修改發行資料夾。可以用 `HP_SMOKE_SKIP` 略過部分測試組，例如：

```bash
HP_SMOKE_SKIP="mirror tls" bash build/build.sh smoke
```

可以略過的組：`payload`、`mirror`、`tls`、`desktop`、`relocate`。各組內容見 [MAINTENANCE.md](MAINTENANCE.md) 第 8 節。

- **真實 profile 檢查（固定執行）**：測試期間 `%USERPROFILE%`、`%APPDATA%`、`%LOCALAPPDATA%` 裡被新增或修改的檔案，除了 Windows 自己的檔案以外都算失敗。在日常使用的電腦上，瀏覽器、編輯器、同步軟體等同時在寫入這些目錄，就會被列為 `FAIL`。請在跑冒煙測試時關閉其他程式；若仍失敗，看清單中的路徑是否與 Hermes 有關，無關的可以忽略。
- **`desktop` 組**：會實際開啟 Hermes Desktop 視窗，需要已登入的桌面工作階段。透過遠端 SSH 或以服務身分執行時請略過。
- **`mirror`、`tls` 組**：第一次需要網路下載測試套件，並使用 Git Bash 內附的 `openssl`。
- **不要設定 `HP_SMOKE_LONGPATHS_OFF=1`**：這是給 CI 的拋棄式 runner 用的。它會修改登錄檔關閉整台電腦的長路徑支援，而且不會改回來。
- 冒煙測試有 `FAIL` 時 `smoke` 步驟會失敗，之後的 `zip` 不會執行。確認失敗與建置無關後，可以單獨執行 `bash build/build.sh zip`。

## 9. 建置前檢查（選用）

對應 CI 的 `checks` job。修改了 `patches/`、`portable/` 或 `build/` 時建議先跑：

```bash
# patch 能套用到固定的 upstream
git -C upstream apply --check "$PWD"/patches/*.patch

# shellcheck（需要 uv）
uvx --from shellcheck-py shellcheck -x -s bash -e SC1091,SC2155,SC2317 \
  build/*.sh build/lib/common.sh build/tests/*.sh \
  portable/lib/*.sh portable/lib/bashrc portable/bin/hermes-portable

# 來源切換與 TLS 整合測試（需要 uv；第一次需要網路）
python -I build/tests/test_sources.py -v
```

`portable/*.cmd` 必須是純 ASCII、CRLF 換行；`.gitattributes` 已處理換行，編輯時不要加入中文。

## 10. 檢查產物

```bash
cd C:/hpb/dist
sha256sum -c Hermes-Portable-*-win-x64.zip.sha256
cat VERSION.txt
```

`VERSION.txt` 中要確認的欄位：

| 欄位 | 意義 |
|---|---|
| `portable=` | 版本，例如 `0.22.5-p1` |
| `pypi_source=`、`npm_source=` | `original` 或建置時使用的 Nexus 網址 |
| `longest_path=` | 壓縮檔內最長的路徑長度 |
| `max_extract_folder_chars=` | 解壓目的資料夾（含結尾 `\`）最多幾個字元，例如 `C:\HP\` 是 6 個 |

接著把 zip 解壓到短路徑，照 [MAINTENANCE.md](MAINTENANCE.md) 第 9 節做手動檢查（TUI、Desktop、`hermes-portable doctor`）。

要在公司內部散布時，請注意 [MAINTENANCE.md](MAINTENANCE.md) 第 11 節的授權要求（FFmpeg、Git for Windows 含 GPL 元件）。

## 11. 疑難排解

| 症狀 | 處理 |
|---|---|
| `no Python 3.11+ found` | 安裝 Python 3.13，或以 `HP_BUILD_PYTHON` 指定完整路徑（第 2 節）。`python` 可能只是 Microsoft Store 的捷徑，`python --version` 會顯示 `Python was not found` |
| `7-Zip not found` | 安裝 7-Zip 到預設位置，或把 `7z.exe` 加入 PATH |
| `run 'build/build.sh patch' first` | `state.env` 不存在：換了 `HP_BUILD_DIR` 或刪過建置目錄，從 `patch` 重跑 |
| `desktop builds require a clean source checkout` | `upstream/` 有未 commit 的修改，重跑 `bash build/build.sh patch` |
| `Filename too long`、找不到檔案 | 第 3 節的長路徑設定沒有生效，或 repo／建置目錄的路徑太長 |
| 檔案被鎖住（`WinError 32`）、建置異常地慢 | Defender 或其他防毒軟體在掃描建置目錄，加入例外（第 3 節） |
| 下載失敗、`SSL: CERTIFICATE_VERIFY_FAILED`、`UNABLE_TO_GET_ISSUER_CERT` | 檢查 Proxy 與憑證設定（第 7.1 節）；封閉網路請設定第 7.3 節的鏡像 |
| `bash: build/build.sh: No such file`，或 `cygpath: command not found` | 用的是 WSL 的 bash，請改用 Git Bash（第 2 節） |
| 冒煙測試的 profile 檢查失敗 | 見第 8 節 |
| 路徑長度超過 `MAX_REL_PATH` | 上游新增了很深的路徑，見 [MAINTENANCE.md](MAINTENANCE.md) 第 10 節 |

其他問題見 [MAINTENANCE.md](MAINTENANCE.md) 第 10 節。
