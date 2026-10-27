# Hermes Portable 維護文件

給維護者：架構、建置、CI、升級上游、更新 patch、發版與疑難排解。使用者面的說明見 [INSTALL.md](INSTALL.md) 與 [CONFIGURATION.md](CONFIGURATION.md)。

## 1. 架構

```
Hermes-Portable/
├─ upstream/        git submodule → NousResearch/hermes-agent，固定在穩定版 tag（build/bundle.conf UPSTREAM_TAG）
├─ patches/         套用到 upstream 的最小修改（git diff 格式，檔頭為說明）
├─ build/           建置腳本（全部是 bash，在 Git Bash 執行）
│  ├─ build.sh      步驟：patch → prepare → package → assemble → smoke → zip
│  ├─ assemble.sh   組出發行資料夾
│  ├─ smoke-test.sh 發行資料夾的冒煙測試
│  ├─ bundle.conf   版本、排除的工具、發行檔名、大小與路徑長度門檻
│  ├─ lib/          common.sh（共用函式）、payload_paths.py（產生 portable/paths.*）
│  └─ tests/        Nexus 格式鏡像、測試 CA、fixture 專案、test_sources.py
├─ portable/        複製進壓縮檔的 Portable 層：啟動檔、env 腳本、hermes-portable、來源切換、SSL hook、managed 設定
├─ docs/            文件（也會複製進壓縮檔）
└─ .github/workflows/build.yml、upstream-bump.yml
```

### 1.1 建置流程

上游已經有完整的 Desktop 打包管線 `scripts/bundles/desktop.py`，Portable 直接沿用：

1. **patch**：把 `upstream` 重設到 submodule 記錄的 commit，以 `git apply --cached` 套用 `patches/*.patch`，並 commit 成一個本地 commit。這個 commit 的作者與日期固定，所以同樣的輸入會得到同樣的 SHA，CI 快取可以重用。Nexus 模式下接著用 `hp_sources.py` 切換鎖定檔，再 commit 一次。結果寫入 `$HP_BUILD_DIR/state.env`。上游管線要求 checkout 必須是乾淨的，所以所有修改都必須 commit。
2. **prepare**：`desktop.py --commit <PATCHED_SHA> --variant bundled --prepare-only`。上游的 PM 會：
   - 下載並以 sha256 驗證固定版本的 python、node、npm、uv、PortableGit、Chromium、ripgrep、ffmpeg
   - 建立 sealed venv（全部 extras，不含選用的 kittentts）
   - 安裝 npm 依賴並準備 Electron 原生模組
3. **package**：`desktop.py --prepared …`。這一步會：
   - 建置 TUI 與 web 前端
   - 完成 agent payload
   - 寫入 build stamp
   - 以 electron-builder `--dir` 產生 `apps/desktop/release/win-unpacked`（patch 0005），payload 位於 `resources/agent-payload`
4. **assemble**：
   - 把 `win-unpacked` 移到 `HermesP-<版本>/desktop`
   - 移除 `uv-cache`（`INCLUDE_UV_CACHE=0`）
   - 把 SSL hook 放進 venv site-packages
   - Nexus 模式時附上 `*.upstream` 原始鎖定檔
   - 複製 Portable 層與文件
   - 產生 `portable/paths.sh` / `paths.cmd`（PortableGit、Python、node… 的實際路徑）、`VERSION.txt`、`licenses/`
5. **smoke**：在發行資料夾的副本上跑測試（第 8 節）。
6. **zip**：檢查最長路徑不超過 `MAX_REL_PATH`（235；259 減去它就是使用者解壓資料夾的長度上限，超過時列出最長的 15 個路徑；assemble 已先刪除超過上限的預編譯 `.pyc`，Python 會改在記憶體中編譯那些模組），以 7-Zip 壓成 Deflate zip，檢查大小不超過 `MAX_ZIP_BYTES`（GitHub Release 單檔上限 2 GiB），產生 `.sha256`。

上游使用 commit build 而不是 tag build，因為 tag build 需要上游內部的 release claim tag。commit build 會讓 Desktop 的更新機制成為 `external`，也就是不會自我更新。副作用是 Desktop 的 exe 檔名會帶上 7 碼 SHA，啟動檔透過 `paths.cmd` 找到它。

### 1.2 執行期流程

```
Hermes-TUI.cmd / Hermes-Shell.cmd / Hermes-Desktop.cmd
  └─ portable\lib\start.cmd   讀 paths.cmd、記下真實使用者資料夾、清掉會影響 bash 的變數
       ├─ console：內建 bash.exe --rcfile portable/lib/bashrc -i   （主控台視窗）
       ├─ exec：   內建 bash.exe portable/lib/run.sh <指令>
       └─ hidden： 內建 mintty --window hide → portable/lib/launch-desktop.sh
            └─ scrub.sh（env -i 白名單）→ env.sh（資料位置、PATH、政策）→ network.sh（Proxy/Nexus/TLS）
```

### 1.3 patches 一覽

| Patch | 修改 | 目的 |
|---|---|---|
| 0001-pm-disable-cua-driver | `pm/packages.py` `CuaDriver.missing_reason()` 永遠回傳原因 | 單一閘門擋下 cua-driver 的所有安裝路徑：打包、預設安裝、更新、明確安裝、執行期間自動安裝 |
| 0002-bundles-exclude-packages | `scripts/bundles/native.py` 讀 `HERMES_BUNDLE_EXCLUDE` | 不打包選用工具（llama.cpp、gh、bws）。若列出必要工具會報錯 |
| 0003-pm-source-agnostic-lock | `pm/packages.py` `_uv_lock_digest()` 忽略 url/registry/upload-time/size | 切換下載來源後 venv 識別碼不變，不會觸發重建 |
| 0004-pm-honor-switched-locks | `pm/environment.py` no_config 模式、`pm/index_config.py` | 已切到鏡像的 `pm/uv.lock` 保留 index 設定（`--locked` 才會通過）；轉送 `UV_SYSTEM_CERTS` |
| 0005-desktop-windows-target-override | `scripts/bundles/desktop.py`、`scripts/releases/commit_build.py` | `HERMES_DESKTOP_WIN_TARGETS=dir` 產生免安裝資料夾；`HERMES_COMMIT_BUILD_VERSION` 讓 commit build 使用 tag 的版本（穩定版 tag 的 pyproject 版本是 0.0.0） |
| 0006-pm-strict-bash-and-artifact-mirror | `pm/shell.py`、`pm/artifact_mirror.py` | `HERMES_GIT_BASH_ONLY=1` 時只使用內建 Git Bash；`HERMES_ARTIFACT_MIRROR` 讓 PM 優先從企業鏡像下載工具 |
| 0007-desktop-no-default-userdata-with-override | `apps/desktop/electron/product-identity.ts` | 設了 `HERMES_DESKTOP_USER_DATA_DIR` 時，不在真正的 `%APPDATA%` 建立 commit build 預設的 userData 資料夾（Electron 以 Known Folder API 取得 appData，不看環境變數） |

原則：patch 要小、要說明清楚，並以環境變數控制（0001 除外），不改上游的預設行為。

## 2. 本機建置

需求：

- Windows 10/11 x64
- Git for Windows（使用它的 Git Bash 執行建置）
- Python 3.11 以上（建議 3.13，用來執行上游的打包腳本）
- 7-Zip（`C:\Program Files\7-Zip\7z.exe` 或在 PATH 中）
- 約 25 GB 可用空間
- 啟用長路徑：`git config --global core.longpaths true`

```bash
git clone --recurse-submodules <本 repo> C:/hp && cd C:/hp
cp build/build.env.example build/build.env   # 選用：Proxy、Nexus、建置目錄等
bash build/build.sh all                      # 或分步：patch prepare package assemble smoke zip
```

- 產物在 `$HP_BUILD_DIR/dist/`（預設 `.build/dist/`），包含資料夾、zip、`.sha256`、`VERSION.txt`。
- `HP_BUILD_DIR` 請放在短路徑，例如 `C:\hpb`。
- 可以只重跑部分步驟。例如只改了 `portable/` 時，執行 `bash build/build.sh assemble smoke zip`。
- prepare 會重用 `$HP_DESKTOP_CACHE`（預設 `.build/desktop-inputs`）中已驗證的下載。
- `HP_BUILD_PYTHON` 可以指定 Python，例如 `py -3.13`。

## 3. CI（`.github/workflows/build.yml`）

| Job | 內容 |
|---|---|
| `checks` | patch 能否套用、shellcheck、`.cmd` 為 ASCII+CRLF、`build/tests/test_sources.py`（本機 Nexus 格式鏡像、私有 CA）、Nexus 模式的 patch 步驟 |
| `build` | Defender 例外、長路徑；`build.sh patch → prepare → package → assemble → smoke → zip`；上傳 artifact |
| `release` | 推送 `v*-p*` tag 時建立 GitHub Release，附上 zip、`.sha256`、`VERSION.txt` |

快取：沿用上游的 `upstream/.github/actions/desktop-build-cache`（producer `desktop`），快取的是 PM 工具與 Python/Node 依賴的下載。PR 只讀取快取，不寫入。

`workflow_dispatch` 的輸入：`runner`、`pypi_index_url`、`npm_registry`、`pypi_lock_mode`、`artifact_mirror`、`electron_mirror`、`proxy`、`no_proxy`、`ssl_insecure`、`smoke_skip`。

Repository 設定（Settings → Secrets and variables → Actions）可提供預設值：

| 名稱 | 類型 | 說明 |
|---|---|---|
| `HP_PYPI_INDEX_URL`、`HP_NPM_REGISTRY` | secret（含帳密時）或 variable | 建置用鏡像 |
| `HP_PYPI_LOCK_MODE`、`HP_PYPI_FILES_TEMPLATE` | variable | 鎖定檔切換方式 |
| `HP_ARTIFACT_MIRROR`、`HP_ELECTRON_MIRROR`、`HP_ELECTRON_BUILDER_BINARIES_MIRROR` | variable | 封閉網路用的二進位檔鏡像 |
| `HP_HTTP_PROXY`、`HP_HTTPS_PROXY`、`HP_NO_PROXY`、`HP_SSL_INSECURE` | variable | 建置網路 |
| `BUMP_TOKEN` | secret | 給 `upstream-bump.yml` 開 PR 用的 PAT（讓 PR 的 CI 會觸發） |

GitHub 代管的 runner 連不到公司內網的 Nexus。Nexus 模式請使用公司內的 self-hosted runner（第 6 節）。

## 4. 發版流程

1. 確認 `main` 的 CI 通過，並在本機或 CI artifact 上做過第 9 節的手動檢查。
2. 決定版本：`v<UPSTREAM_TAG 去掉 v>-p<PORTABLE_REVISION>`。
   - 同一個 upstream 的 Portable 修正：把 `build/bundle.conf` 的 `PORTABLE_REVISION` 加 1。
   - 換了 upstream：`PORTABLE_REVISION=1`。
3. commit 之後打 tag 並推送，例如：

   ```bash
   git tag v0.22.5-p1 && git push origin v0.22.5-p1
   ```

4. CI 會檢查 tag 與 `VERSION.txt` 的 `portable=` 是否一致，再建立 Release。

## 5. 升級上游

### 5.1 自動（`upstream-bump.yml`，每週一）

- 用 `git ls-remote` 找最新的穩定版 tag（`vX.Y.Z`，不含 canary）。
- 若比 `bundle.conf` 的 `UPSTREAM_TAG` 新，就移動 submodule 並逐一以 `git apply --check` 檢查 patch：
  - 全部通過 → 開 PR，同時更新 `UPSTREAM_TAG`，並把 `PORTABLE_REVISION` 重設為 1。
  - 有失敗 → 開 issue，列出需要更新的 patch。

審 PR 時，請閱讀上游 release notes 中與以下部分相關的變更：

- `pm/`、`scripts/bundles/`、`scripts/build/`
- `apps/desktop/`
- 啟動器（`hermes_cli/_launchers.py`）
- 設定鍵（`hermes_cli/config_defaults.py`），尤其是 managed 設定用到的那幾個鍵

### 5.2 手動

```bash
TAG=v0.22.6
git -C upstream fetch --depth 1 origin tag "$TAG"
git -C upstream checkout "$TAG"
git -C upstream apply --check "$PWD"/patches/*.patch     # 失敗時見 5.3
sed -i "s/^UPSTREAM_TAG=.*/UPSTREAM_TAG=$TAG/; s/^PORTABLE_REVISION=.*/PORTABLE_REVISION=1/" build/bundle.conf
git add upstream build/bundle.conf && git commit -m "Bump upstream Hermes Agent to $TAG"
bash build/build.sh all
```

`build.sh patch` 會確認 `UPSTREAM_TAG` 真的指向 submodule 記錄的 commit。

### 5.3 更新失效的 patch

```bash
cd upstream
git checkout --detach "$TAG"
git apply --3way ../patches/0003-pm-source-agnostic-lock.patch   # 逐一處理失敗的 patch
# 解決衝突，確認修改仍然符合 patch 檔頭說明的目的
{ sed -n '1,/^diff --git/p' ../patches/0003-pm-source-agnostic-lock.patch | sed '$d'; git diff HEAD; } > /tmp/new.patch
mv /tmp/new.patch ../patches/0003-pm-source-agnostic-lock.patch
git reset -q --hard && git apply --check ../patches/*.patch
```

- 要保留 patch 檔頭的說明段落，`git apply` 會忽略第一個 `diff --git` 之前的文字。
- 若上游已經提供等效功能（例如可設定的打包排除清單），請刪除對應的 patch，並更新本文件第 1.3 節與相關腳本。
- 確認 patch 依賴的錨點仍存在。修改 patch 後請跑 `python -I build/tests/test_sources.py`，以及完整建置與冒煙測試：
  - 0001：`missing_reason` 的呼叫點
  - 0003：`_uv_lock_digest` 的使用處
  - 0005：`desktop.py` 的 targets、`version_at`

## 6. Nexus 模式建置與封閉網路

建置流程使用與 Portable 執行期相同的 `HP_*` 設定（`build/build.env`、環境變數或 CI 輸入）：

| 設定 | 效果 |
|---|---|
| `HP_PYPI_INDEX_URL` | patch 步驟把 upstream 的 `uv.lock`、`pm/uv.lock` 切換到鏡像並 commit。之後 PM 的 `uv sync --frozen` 全部從 Nexus 下載 |
| `HP_NPM_REGISTRY` | 把 upstream 所有 `package-lock.json` 切到鏡像。`npm ci` 從 Nexus 下載，不依賴 `.npmrc`，因為上游的建置流程會把 HOME 隔離掉 |
| `HP_PYPI_LOCK_MODE` | `discover`（預設，讀鏡像的 simple 頁面）或 `rewrite`（網址樣板） |
| `HP_ARTIFACT_MIRROR` | PM 工具（Python、Node、PortableGit、Chromium、ffmpeg、uv、ripgrep）優先從這個 raw proxy 下載（`<鏡像>/upstream/sha256/<sha256>`），仍以 sha256 驗證 |
| `HP_ELECTRON_MIRROR`、`HP_ELECTRON_BUILDER_BINARIES_MIRROR` | electron-builder 下載 Electron 與打包工具的鏡像 |
| `HP_HTTP(S)_PROXY`、`HP_SSL_*` | 與執行期相同 |

完全封閉的網路需要以下 Nexus 儲存庫：

- PyPI proxy（`https://pypi.org/`）
- npm proxy（`https://registry.npmjs.org/`）
- raw proxy：`https://hermes-assets.nousresearch.com/`
- raw proxy：`https://github.com/electron/electron/releases/download/`
- raw proxy：`https://github.com/electron-userland/electron-builder-binaries/releases/download/`

uv.lock 中的 git 來源（misaki）只屬於 kittentts，而打包不含 kittentts，所以不需要連 GitHub。

self-hosted runner：

- Windows x64，安裝 Git for Windows、7-Zip，Python 由 `actions/setup-python` 安裝。
- runner 版本需 2.327.1 以上：工作流程使用的 actions 都是 Node 24 版本。
- 約 30 GB 可用空間，並啟用長路徑（`LongPathsEnabled=1`）。
- 用 `runner` 輸入指定它的 label。
- 建置產物會帶有 `.upstream` 原始鎖定檔，`VERSION.txt` 會記錄 `pypi_source` / `npm_source`。

## 7. 調整打包內容

`build/bundle.conf`：

- `BUNDLE_EXCLUDE`：不打包的選用 PM 工具（fnmatch，逗號分隔）。目前是 `llamacpp-*,gh,bws`。被排除的工具仍可在需要時由 Hermes 下載（`HP_ALLOW_LAZY_INSTALLS`），來源是 GitHub 或 `HP_ARTIFACT_MIRROR`。
- `INCLUDE_UV_CACHE`：`1` 時附上 uv wheel 快取（可離線重建 venv，但壓縮檔會大很多）。
- `MAX_ZIP_BYTES`、`MAX_REL_PATH`：發行門檻。超過時建置會失敗，避免發出無法上傳或無法解壓的檔案。

## 8. 冒煙測試（`build/smoke-test.sh`）

在發行資料夾的**副本**上執行，發行資料夾本身不會被修改。各組測試可以用 `HP_SMOKE_SKIP` 略過。

| 組 | 檢查 |
|---|---|
| payload | 上游 `scripts/smoke-payload.sh`：搬移 payload 後離線執行 `--version`、`--help`、`tools list`、`pm doctor`（工具 digest）、browser-harness |
| （固定） | `Hermes-Shell.cmd hermes --version`；主機變數不外洩、`HP_ENV_PASSTHROUGH` 有效；工具都來自資料夾內；`pm.shell.bash()` 是內建 Git Bash；`tools list`；cua-driver 安裝被拒；`hermes update` 被拒；`hermes-portable doctor` |
| （固定） | 在真實 payload 鎖定檔上做 rewrite 切換 → verify → venv 識別碼不變 → `hermes --version` → 逐位元組還原 |
| mirror | Nexus 格式本機鏡像 + 黑洞 Proxy：discover 切換、`uv sync --frozen`、`npm ci`、verify |
| tls | 私有 CA 的 HTTPS 鏡像：預設拒絕；`HP_SSL_CA_FILE` 與 `HP_SSL_INSECURE` 下 uv、curl、node、httpx、requests、來源切換都要成功 |
| desktop | 啟動 Desktop（盡力而為：代管 runner 的桌面環境有限）、不寫入 `HKCU\Software\Classes\hermes` |
| relocate | 關閉長路徑支援後，把資料夾搬到含空白與中文的短路徑，重跑主要檢查，並確認路徑最長的 payload 原始檔仍讀得到 |

## 9. 發版前手動檢查（需要真實桌面）

- [ ] `Hermes-TUI.cmd`：TUI 正常顯示、可對話；離開後留在 Git Bash 提示字元
- [ ] `Hermes-Desktop.cmd`：視窗出現、可對話；終端機面板是 Git Bash；關閉後背景 gateway 停止（工作管理員中沒有殘留的 hermes 或 python 程序）
- [ ] `Hermes-Shell.cmd`：`hermes-portable doctor` 全部 OK
- [ ] 在公司網路：設定 `portable.env` → `sources pypi/npm use-nexus` → `verify` → `doctor`
- [ ] 把資料夾搬到其他路徑後再試一次

## 10. 疑難排解

| 症狀 | 處理 |
|---|---|
| `patch no longer applies` | 見第 5.3 節 |
| `UPSTREAM_TAG ... does not point at the pinned submodule commit` | `bundle.conf` 與 submodule 不一致，請兩者一起更新 |
| prepare 下載失敗 | 檢查 Proxy/憑證設定；封閉網路請設定 `HP_ARTIFACT_MIRROR` 與 Electron 鏡像；可以刪除 `$HP_DESKTOP_CACHE` 重新下載 |
| prepare 出現 `desktop builds require a clean source checkout` | upstream 裡有未 commit 的修改；重新執行 `build.sh patch` |
| 檔案被鎖住（WinError 32）、建置很慢 | Defender 正在掃描建置目錄；請加入例外（CI 已處理） |
| zip 超過大小門檻 | 檢查 `BUNDLE_EXCLUDE`、`INCLUDE_UV_CACHE`；查看上游新增的大型依賴 |
| 路徑長度超過門檻 | 縮短 `DIST_DIR_PREFIX`；若是上游新增了很深的路徑，評估是否提高門檻，並同步更新 INSTALL.md 的解壓建議 |
| 冒煙測試找不到 Desktop exe | `payload_paths.py` 取 `desktop/` 中最大的 exe；若上游改變了產物結構，請更新它 |
| `pm doctor` 回報 digest 不符 | 有東西寫進了 `tools/`。確認腳本沒有對 PortableGit 寫入 `git config --system`，或修改了工具目錄 |

## 11. 授權合規

- 壓縮檔的 `licenses/` 收錄 Hermes Agent（MIT）、Electron/Chromium，以及各工具目錄中的授權檔，並附上 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
- FFmpeg 使用 GPL 版建置，Git for Windows / MSYS2 含 GPL 元件。散布時須提供對應的原始碼取得方式。`THIRD-PARTY-NOTICES.md` 列出了各元件的版本與原始碼位置，升級 upstream 後若工具版本改變（`VERSION.txt` 的 `tool.*`），請同步更新該文件。
