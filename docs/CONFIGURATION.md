# Hermes Portable 設定說明

本文件說明 Hermes Portable 的設定方式：環境隔離、`config\portable.env` 的全部欄位、套件來源切換（Nexus）、Proxy 與憑證，以及強制套用的設定。

## 1. 設定檔與優先順序

| 檔案 | 誰讀取 | 用途 |
|---|---|---|
| `config\portable.env` | Portable 啟動腳本 | Portable 層設定（`HP_*`）與要給 Hermes 的環境變數。從 `config\portable.env.example` 複製而來 |
| `data\hermes\.env` | Hermes | Hermes 自己的環境變數檔（API Key 等），優先於程序環境 |
| `data\hermes\config.yaml` | Hermes | Hermes 一般設定（模型、工具、介面…），由 `hermes setup` / Desktop 維護 |
| `portable\managed\config.yaml` | Hermes（managed scope） | Portable 強制設定，覆蓋所有 profile，使用者無法修改（見第 7 節） |

`portable.env` 的格式：

- 每行一筆 `KEY=VALUE`，以 `#` 開頭的行是註解，值可以加引號。
- 用記事本存檔產生的 CRLF 換行也能正確讀取。
- `${HP_ROOT}`（或 `%HP_ROOT%`）會展開為 Portable 資料夾的路徑。路徑欄位若是相對路徑，以 Portable 資料夾為起點。
- 檔案內容**不會**被當成程式執行，只做純文字解析。
- `HP_*` 開頭的是 Portable 設定，其他 `KEY=VALUE` 原樣匯出給 Hermes，例如 `OPENAI_API_KEY=...`。

## 2. 環境隔離

每次啟動都從乾淨的環境開始，主機上的環境變數不會影響 Hermes：

1. `.cmd` 啟動檔先清掉會影響 bash 啟動的變數（`BASH_ENV`、`MSYS`、`HOME`…），並把 PATH 縮減到 System32。
2. `portable\lib\scrub.sh` 以 `env -i` 重新啟動 bash，只保留白名單中的變數（`portable\lib\env-allowlist.txt`，只有 Windows 執行必需的 `SYSTEMROOT`、`TEMP`、`USERNAME`… 等），再加上 `HP_ENV_PASSTHROUGH` 列出的名稱。
3. `portable\lib\env.sh` 依 `portable.env` 建立 Hermes 需要的所有變數。

因此全域的 `OPENAI_API_KEY`、`PYTHONPATH`、`NODE_OPTIONS`、`UV_*`、`npm_config_*`、`HTTP_PROXY`、`HERMES_*` 等**都不會**傳入。使用者層級的 `.npmrc`、`.gitconfig`、`pip.ini` 也不會被讀到，因為家目錄已經改到 Portable 資料夾內。

| 變數 | Portable 中的值 |
|---|---|
| `HERMES_HOME` | `data\hermes` |
| `HOME`、`USERPROFILE` | `data\home` |
| `APPDATA`、`LOCALAPPDATA` | `data\home\AppData\Roaming`、`data\home\AppData\Local` |
| `HERMES_DESKTOP_USER_DATA_DIR` | `data\desktop`（Electron 使用者資料） |
| `GIT_CONFIG_GLOBAL` | `data\home\.gitconfig` |
| `npm_config_cache`、`HF_HOME` | `data\cache\npm`、`data\cache\hf` |
| `HERMES_MANAGED_DIR` | `portable\managed` |
| `HERMES_GIT_BASH_ONLY`、`HERMES_GIT_BASH_PATH` | 只使用內建 Git Bash |
| `HERMES_DESKTOP_SKIP_PROTOCOL_REGISTRATION` | `1`（不在登錄檔註冊 `hermes://`） |
| `PATH` | Hermes 指令、內建 node/npm/uv/rg/ffmpeg、PortableGit、`/mingw64/bin`、`/usr/bin`、System32 |
| `HP_REAL_USERPROFILE` | 你真正的 Windows 使用者資料夾，僅供參考 |

`hermes-portable env` 可以顯示目前生效的設定，密碼與金鑰會遮蔽。

### 2.1 不會留在 Portable 資料夾內的東西

設定與快取都在 `data\`。CI 的冒煙測試（`build/smoke-test.sh` 第 8 組）會掃描真正的 `%USERPROFILE%`、`%APPDATA%`、`%LOCALAPPDATA%`，只要經由啟動檔執行的任何程式在那裡新增或修改檔案，測試就會失敗。以下例外是刻意的，或屬於 Windows 本身：

- **`%TEMP%`**：保留系統的暫存資料夾（白名單中的 `TEMP`／`TMP`）。工具的暫存檔會留在這裡，但這些不是設定檔。
- **起始目錄**：Shell、TUI 與 Desktop 預設從你真正的使用者資料夾開始（`HP_START_DIR` 可改）。Hermes 在你指定的專案中工作時當然會寫入那裡。
- **Windows 自己的紀錄**：登錄檔 hive（`NTUSER.DAT`）、`AppData\Local\Microsoft\` 底下的快取、Direct3D 著色器快取（`AppData\Local\D3DSCache`），以及程式當機時的 `AppData\Local\CrashDumps`。這些由 Windows 寫入，不受環境變數影響。

會改變登錄檔的 `hermes://` 協定註冊已經關閉（見上表）。Electron 以 Windows Known Folder API 取得 `%APPDATA%`，不看環境變數；patch 0007 避免它在真正的 `%APPDATA%` 建立資料夾。

## 3. `portable.env` 欄位一覽

| 欄位 | 預設 | 說明 | 對應到 |
|---|---|---|---|
| `HP_PYPI_INDEX_URL` | （空：PyPI） | PyPI 鏡像 simple index，可內嵌帳密 `https://user:pass@host/...` | `UV_DEFAULT_INDEX`、`PIP_INDEX_URL`；`sources pypi use-nexus` 的預設來源 |
| `HP_PYPI_EXTRA_INDEX_URLS` | | 額外的 index，以空白或逗號分隔 | `UV_INDEX`、`PIP_EXTRA_INDEX_URL` |
| `HP_PYPI_FILES_TEMPLATE` | `nexus` | `--mode rewrite` 使用的網址樣板（第 4 節） | |
| `HP_NPM_REGISTRY` | （空：npmjs） | npm 鏡像 registry，可內嵌帳密 | `.npmrc` 的 `registry`、`npm_config_registry`；`sources npm use-nexus` 的預設來源 |
| `HP_NPM_AUTH_TOKEN` | | npm registry 的 token | `.npmrc` 的 `//host/path/:_authToken` |
| `HP_ARTIFACT_MIRROR` | | `https://hermes-assets.nousresearch.com` 的 raw proxy。Hermes 依需求下載工具（Python、Node、Chromium…）時使用，以 sha256 驗證 | `HERMES_ARTIFACT_MIRROR`（patch 0006） |
| `HP_HF_ENDPOINT` | | Hugging Face 鏡像（本機語音模型等） | `HF_ENDPOINT` |
| `HP_HTTP_PROXY` | | HTTP Proxy | `HTTP_PROXY`/`http_proxy`、npm `proxy` |
| `HP_HTTPS_PROXY` | 同 `HP_HTTP_PROXY` | HTTPS Proxy | `HTTPS_PROXY`/`https_proxy`、npm `https-proxy`、git `http.proxy`、Desktop `--proxy-server` |
| `HP_NO_PROXY` | | 不走 Proxy 的主機（localhost、127.0.0.1、::1 一律自動加入） | `NO_PROXY`/`no_proxy`、npm `noproxy`、Desktop `--proxy-bypass-list` |
| `HP_SSL_USE_SYSTEM_STORE` | `1` | 使用 Windows 憑證存放區 | `UV_SYSTEM_CERTS`、`NODE_USE_SYSTEM_CA`、git `http.sslBackend=schannel`（不檢查撤銷）、curl `ssl-revoke-best-effort` |
| `HP_SSL_CA_FILE` | | 額外的 CA 憑證（PEM），與公開根憑證合併成 `data\cache\ca-bundle.pem` | `SSL_CERT_FILE`、`REQUESTS_CA_BUNDLE`、`CURL_CA_BUNDLE`、`~/.curlrc` 的 `cacert`（內建 curl 只認這個）、`GIT_SSL_CAINFO`、npm `cafile`、`NODE_EXTRA_CA_CERTS` |
| `HP_SSL_INSECURE` | `0` | **最後手段**：完全不驗證 TLS 憑證（第 6 節） | 見第 6 節 |
| `HP_SSL_INSECURE_HOSTS` | | 額外加入 uv 不驗證清單的主機 | `UV_INSECURE_HOST` |
| `HP_ENV_PASSTHROUGH` | | 允許從主機繼承的變數名稱（可用萬用字元，例如 `AZURE_*`） | |
| `HP_INHERIT_PATH` | `0` | `1` 時把 Windows 原本的 PATH 接在內建工具之後 | `PATH` |
| `HP_DATA_DIR` | `data` | 資料資料夾位置 | `HERMES_HOME` 等 |
| `HP_START_DIR` | 你的使用者資料夾 | Shell、TUI、Desktop 終端機的起始目錄 | `HERMES_DESKTOP_CWD` |
| `HP_ALLOW_LAZY_INSTALLS` | `1` | `0` 時禁止 Hermes 在首次使用功能時自動下載元件 | `HERMES_DISABLE_LAZY_INSTALLS=1` |
| `HP_STOP_GATEWAY_ON_EXIT` | `1` | 最後一個 Desktop 視窗關閉時停止背景 gateway | |
| `HP_EXIT_AFTER_AUTORUN` | `0` | `1` 時 TUI 結束後直接關閉視窗 | |

## 4. 套件來源切換（Nexus）

### 4.1 為什麼要切換「鎖定檔本身」

Hermes 以 `uv sync --frozen` 依照 `uv.lock` 安裝 Python 套件。`uv.lock` 裡每個檔案都寫死了完整的下載網址（`https://files.pythonhosted.org/...`）。`--frozen` 會直接使用這些網址，**完全不理會** `UV_DEFAULT_INDEX` / `UV_INDEX_URL`，所以只設定 index 無法讓安裝改走 Nexus。npm 的 `package-lock.json` 也一樣，寫死了 `https://registry.npmjs.org/...`。

Portable 的作法是把鎖定檔裡的**下載網址**換成 Nexus：

- 套件名稱、版本、sha256 雜湊**完全不變**，安裝時仍以原始雜湊驗證每個檔案。
- 沒有設定也沒有切換時，就使用原始鎖定檔與原始來源。
- 第一次切換時，原始鎖定檔會保存為 `<鎖定檔>.upstream`，`use-original` 會逐位元組還原。
- 只換下載來源時，Python 環境的識別碼不變（patch 0003），切換後**不會**觸發整個 venv 重建。

切換的對象：

- `desktop\resources\agent-payload\hermes-agent\uv.lock`（Hermes）
- `...\hermes-agent\pm\uv.lock`（Hermes 套件管理器 PM 自身的執行環境）
- 該目錄下所有 `package-lock.json`

### 4.2 指令

```bash
hermes-portable sources status            # 每個鎖定檔目前的來源；--check 時，設定與鎖定檔不一致就回傳 1
hermes-portable sources pypi use-nexus    # 切換 uv.lock（預設使用 HP_PYPI_INDEX_URL）
hermes-portable sources pypi use-original # 還原
hermes-portable sources npm use-nexus     # 切換 package-lock.json（預設使用 HP_NPM_REGISTRY）
hermes-portable sources npm use-original  # 還原
hermes-portable sources verify            # 比對 .upstream：名稱、版本、雜湊必須完全相同
hermes-portable sources check-url URL...  # 用目前的 Proxy/憑證設定測試連線
```

`pypi use-nexus` 的選項：

| 選項 | 說明 |
|---|---|
| `--index-url URL` | 指定鏡像網址，不用 `HP_PYPI_INDEX_URL` |
| `--mode discover`（預設） | 逐一讀取鏡像的 PEP 503 simple 頁面（`<index>/<套件>/`），找到每個鎖定檔案在鏡像上的實際網址，並用頁面提供的 sha256 交叉比對。適用於 Nexus、Artifactory、devpi 等任何相容的 index，需要能連到鏡像 |
| `--mode rewrite` | 不查詢鏡像，直接用網址樣板改寫。速度快，可離線準備，但要知道鏡像的路徑格式 |
| `--files-template` | `nexus`（預設，`{index_root}/packages/{name}/{version}/{filename}`）、`artifactory`（`{index_root}/packages/{path}`），或自訂樣板。可用變數：`{index_root}`（去掉結尾 `/simple` 的 index）、`{index}`、`{name}`、`{version}`、`{filename}`、`{path}`（原始網址中 files.pythonhosted.org 之後的路徑） |
| `--allow-missing` | 鏡像上找不到的檔案保留原網址，不視為錯誤 |
| `--no-probe` | 跳過切換前的下載測試（預設會實際試抓數個檔案，失敗就不寫入） |

注意事項：

- **帳密**：網址中的帳密只用於連線，不會寫進鎖定檔。uv 從 `UV_DEFAULT_INDEX` 取得同一主機的帳密。npm 的帳密由 `HP_NPM_AUTH_TOKEN`，或內嵌在 `HP_NPM_REGISTRY` 的 `user:pass` 產生到 `.npmrc`。
- **無法切換的項目**：`uv.lock` 中少數直接引用 GitHub 的套件（`kittentts` URL、`misaki` 與 `psutil` 的 git 來源）不屬於 PyPI。它們只在選用功能（KittenTTS）或 Android 上使用，`sources status` 會列出來。
- **設定與鎖定檔要一致**：設定了 `HP_PYPI_INDEX_URL` 卻還沒切換時，新解析的套件（uvx、外掛）會走 Nexus，但依鎖定檔安裝的套件仍會嘗試連 PyPI。`hermes-portable doctor` 會提示這種不一致。
- **建議的 Nexus 設定**：
  - PyPI proxy → `https://pypi.org/`
  - npm proxy → `https://registry.npmjs.org/`
  - （選用）raw proxy → `https://hermes-assets.nousresearch.com/`，供 `HP_ARTIFACT_MIRROR` 使用
  - （選用）Hugging Face proxy
  - npm proxy 需要提供完整的套件 metadata（含發佈時間）。

### 4.3 建置時切換

建置流程也支援整個改用 Nexus（`build/build.env` 或 CI 輸入的 `HP_PYPI_INDEX_URL` / `HP_NPM_REGISTRY`），見 [MAINTENANCE.md](MAINTENANCE.md#6-nexus-模式建置與封閉網路)。用 Nexus 建置出的壓縮檔，鎖定檔已經指向 Nexus，並附有 `.upstream` 原始檔，可以用 `use-original` 改回公開來源。

## 5. Proxy

設定 `HP_HTTPS_PROXY`（以及 `HP_HTTP_PROXY`）後，Portable 會設定以下各處：

- 大小寫兩種 `*_PROXY` 環境變數（Hermes、uv、curl、git 都會讀）
- `.npmrc` 的 `proxy`、`https-proxy`、`noproxy`
- `NODE_USE_ENV_PROXY=1`，讓 Node 的 `fetch` 也使用 Proxy
- git 的 `http.proxy`
- Hermes Desktop（Chromium）的 `--proxy-server`、`--proxy-bypass-list`

Proxy 網址可以內嵌帳密：`http://user:pass@proxy:8080`。

## 6. TLS 憑證（三層）

1. **Windows 憑證存放區**（預設，`HP_SSL_USE_SYSTEM_STORE=1`）：最推薦。公司以群組原則派送的根憑證，或使用者自行匯入的根憑證（`certutil -user -addstore Root corp-root.cer`，不需要系統管理員權限），會被以下元件信任：
   - uv（`UV_SYSTEM_CERTS`）
   - Node/npm（`NODE_USE_SYSTEM_CA`）
   - Git（schannel）
   - Hermes 的 Python（truststore）
   - Desktop
2. **額外 CA 檔**（`HP_SSL_CA_FILE=config\corp-root-ca.pem`）：無法匯入系統存放區時使用。這個檔案會與公開根憑證合併，供 Python、uv、curl、git、npm 使用，Node 另外以 `NODE_EXTRA_CA_CERTS` 載入。設定後 git 改用 OpenSSL 後端。
3. **完全不驗證**（`HP_SSL_INSECURE=1`）：最後手段，會讓中間人攻擊無法被察覺。只在信任的解密 Proxy 環境、且前兩種方式都不可行時使用。效果如下：
   - uv：`UV_INSECURE_HOST`（自動包含鏡像、PyPI、GitHub 等主機）
   - npm：`strict-ssl=false`
   - Node：`NODE_TLS_REJECT_UNAUTHORIZED=0`
   - git：`GIT_SSL_NO_VERIFY=1`
   - curl：`~/.curlrc` 寫入 `insecure`
   - Desktop：`--ignore-certificate-errors`
   - Hermes 的 Python：由 `hp_sslhook` 讓 ssl / httpx / requests / truststore 都不驗證
   - 限制：PM 下載工具的背景程序以隔離模式執行，不受 hook 影響。需要時請搭配第 1 或第 2 層。

## 7. 強制設定（managed scope）

`portable\managed\config.yaml` 會覆蓋所有 profile 的設定，使用者無法修改：

| 設定 | 值 | 原因 |
|---|---|---|
| `agent.disabled_toolsets` | `[computer_use]` | 不提供 cua-driver（電腦操作） |
| `updates.check` | `false` | 更新改由新版 Portable 壓縮檔提供 |
| `updates.refresh_cua_driver` | `false` | 同上 |
| `computer_use.autostart` | `false` | 不註冊排程工作 |
| `telemetry.shared_metrics.enabled` / `send` | `false` | 不回傳使用統計 |

另外，patch 0001 讓 Hermes 的套件管理器把 cua-driver 視為「此發行版不提供」。因此預設安裝、`hermes update`、`hermes computer-use install`、執行期間自動安裝都會被拒絕。

## 8. 企業環境範例

```ini
# config\portable.env
HP_PYPI_INDEX_URL=https://nexus.corp.example/repository/pypi-group/simple
HP_NPM_REGISTRY=https://nexus.corp.example/repository/npm-group/
HP_NPM_AUTH_TOKEN=NpmToken.xxxxxxxx
HP_ARTIFACT_MIRROR=https://nexus.corp.example/repository/hermes-assets
HP_HTTPS_PROXY=http://proxy.corp.example:8080
HP_HTTP_PROXY=http://proxy.corp.example:8080
HP_NO_PROXY=.corp.example,10.0.0.0/8
HP_SSL_CA_FILE=config\corp-root-ca.pem
OPENAI_API_KEY=sk-...
```

接著在 `Hermes-Shell.cmd` 中執行：

```bash
hermes-portable sources pypi use-nexus
hermes-portable sources npm use-nexus
hermes-portable sources verify
hermes-portable doctor
```

## 9. 診斷

- `hermes-portable doctor` 會檢查：
  - 內建工具的位置（不能來自 Portable 資料夾以外）
  - `hermes --version`
  - `data\` 是否可寫入
  - 鎖定檔來源與設定是否一致
  - 透過目前的 Proxy/憑證設定能否連到 PyPI/npm 鏡像
- `hermes-portable env`：顯示生效中的設定（敏感值遮蔽）。
- 紀錄檔：
  - `data\logs\desktop-launcher.log`（Desktop 啟動腳本）
  - `data\hermes\logs\`（Hermes 與 Desktop）
