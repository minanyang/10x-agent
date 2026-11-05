<div align="center">

# 10x Agent

交付程式碼的 multi-agent workflow：agent 規劃、實作、審查，沒有 script 能驗證的證據就不合併。

[![Release](https://img.shields.io/github/v/release/minanyang/10x-agent)](https://github.com/minanyang/10x-agent/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-D97757)](https://code.claude.com/docs/en/plugins)

[English](README.md) · **繁體中文**

</div>

每張 ticket 都先和你一起規劃，在自己的 worktree 裡實作，由 script 驗證而不是聽 agent 說「好了」，再交給一個完全沒看過實作過程的 agent 審查，最後才合併。10x Agent 是 Claude Code 的 plugin；之後也會推出 Codex 版。

## 為什麼需要 10x Agent

放手讓 coding agent 自己做，常見的狀況是：

- **沒驗證就回報完成**：它說測試過了，不代表測試真的有跑；
- **計畫很模糊**：怎樣算做完、會動到哪些檔案、還有誰依賴這些檔案，都沒寫下來；
- **合併前沒人把關**：寫程式的和審程式的是同一個 context。

10x Agent 把每張 ticket 變成一個不靠 agent 自述的流程：

- 一個 session 只處理一張 ticket，下一個 session 需要的東西都在 `.10x/<id>/`；
- 實作一律在獨立的 worktree，不碰 main checkout；
- 計畫要有編號的驗收條件，給你看之前先由 script 檢查過；
- 由 script 驗證：跑專案的 gates，而且新測試在拿掉改動後必須失敗；
- 審查的 agent 只拿到 diff 和計畫，拿不到實作者的說法；
- 每一步都會停下來，讓你可以介入。

## 指令

```
/10x:open <idea>     →  draft a ticket ─(you approve)→ GitHub issue gh-<n>, or .10x/<slug>/ticket.md
/10x:work <ticket>   →  plan  ─(you approve)→  worktree → tests → commit → red-proof --lock → implement → commit → red-proof → pre-review gates → verify + cold review → fix → review the fixes
/10x:close <id>      →  rebase → verify → PR / merge → clean up
/10x:roadmap [reqs]  →  order requirements into versions; /10x:batch <version> runs one
/10x:audit           →  run the installed security-audit skill on a scope; merge its findings into .10x/security.md and settle each one
/10x:batch <tickets> →  work and close many tickets from one terminal, each in a background worker
```

**`/10x:open <idea>`** 把一個想法、bug 或改進變成 GitHub issue，套用 repo 自己的 issue form、label 和 issue type；設定 `tickets: files` 時，則變成 `.10x/` 底下的 ticket 檔案，只留在你的電腦上。它會先問清楚這個想法沒交代的產品問題，把草稿給你看，你核准後才建立 ticket。

**`/10x:work <ticket>`** 可以接一個 issue，或一段文字描述的任務。它先規劃：問技術問題，寫出計畫，包含驗收條件、會動到的檔案、證明每個條件的測試，然後停下來等你核准。接著在 worktree 裡先 commit 會失敗的測試並鎖定，再實作、同時跑 gates 和冷審查、修正審查找到的問題，最後回報。鎖定的測試只能透過全新 context 的審查者核准的 relock 修改；設定 `"tdd": false` 即可關閉鎖定。

**`/10x:close <id>`** rebase、再驗證一次，然後把整個 branch 壓成一個 squash commit 落地：開 PR 讓你合併、開 PR 並在 checks 通過後自己合併，或在本機合併，最後清理現場。

每一步的細節見 [docs/loop.md](docs/loop.md)（英文）。

## 安裝

```
/plugin marketplace add minanyang/claude-plugins
/plugin install 10x@minanyang
```

需要 `git` 和 `node`（18 以上）。GitHub issue 形式的 ticket（`tickets: github`，`/10x:open` 會建立這種 ticket），以及 `pr` / `pr-merge` 兩種 close 模式，還需要已登入的 [`gh`](https://cli.github.com)（`gh auth login`），GitLab 則用 [`glab`](https://gitlab.com/gitlab-org/cli)；沒有的話，`tickets: files` 和 `close: local` 一樣能用。10x Agent 在 push 之前會先檢查，缺什麼會告訴你。

### 快速開始

```
/10x:open add a --json flag to the export command
/10x:work 12
/10x:close gh-12
```

1. `/10x:open` 問完問題、給你看草稿，你核准後建立 issue（假設是 #12）。
2. `/10x:work 12` 為 ticket `gh-12` 寫計畫，然後停下來。看完計畫、回答問題或核准後，再執行一次 `/10x:work gh-12`（或直接說「go」）開始實作。
3. `/10x:close gh-12` 把它落地。預設會開 PR；你合併之後，再執行一次 `/10x:close gh-12` 清理。

base branch、gates、close 模式、ticket 放在哪裡等選用設定放在 `.claude/10x.json`，見 [docs/configuration.md](docs/configuration.md)（英文）。`tickets` 可以是 `"github"`（GitHub issue）或 `"files"`（`.10x/<slug>/ticket.md`，不會被 push）；沒設定時，`origin` 在 github.com 的 repo 用 `github`，其他一律用 `files`。它和 `close` 互不相干：repo 可以把 ticket 檔案留在本機，照樣用 PR 落地；不過在 `pr` 和 `pr-merge` 模式下，PR 內文仍會帶出計畫的目標和驗收條件。

## 批次處理

`/10x:batch gh-12 gh-13` 或 `--search "label:bug"` 會規劃所有 ticket，並在同一輪裡問你。`.10x/_batch/board.md` 列出每張 ticket 的階段、session 和結果。

- `batch.parallel` 限制同時實作的 worker 數（預設 `1`）；ticket 一次落地一張。
- `claude --resume <session id>` 可以進入某個 worker。
- 規劃階段只會寫入 `.10x/`。核准之後，worker 會在無人看守下依 ticket 內容改檔、執行指令：只批次處理你信任的 issue。
- 要允許 `Bash(git -C * add *)` 和 `Bash(git -C * commit *)`（[注意事項](tests/e2e/README.md)）；其他被拒絕的指令會列在 board 上。
- `pr` 模式下，檔案重疊的 ticket 會產生重疊的 PR；大於 1 時，agent memory 會落在多個 branch。

## 內容

### Agents

呼叫時要寫成 `10x:<name>`（Agent tool 需要這個前綴）。

| Agent | 負責 | 不負責 |
|---|---|---|
| `10x:frontend-engineer` | 在專案現有的前端 stack 裡改 UI | 後端、基礎設施 |
| `10x:backend-engineer` | API、資料存取、伺服器端邏輯 | UI、基礎設施 |
| `10x:devops-engineer` | CI/CD、container、IaC、部署設定 | 應用程式碼 |
| `10x:qa-engineer` | 測試設計、重現 bug、排查不穩定的測試 | 修正式環境的 bug |
| `10x:code-reviewer` | 冷審查；只回報有 80% 以上把握的問題，唯讀 | 修正 |
| `10x:security-reviewer` | 資安審查、威脅建模、相依套件稽核，唯讀 | 修正 |

### Skills

| Skill | 用途 |
|---|---|
| `/10x:open` | 起草 ticket（GitHub issue，或設定 `tickets: files` 時 `.10x/` 底下的檔案），核准後建立 |
| `/10x:work` | 規劃 ticket，再到 worktree 裡實作、驗證、審查 |
| `/10x:close` | rebase、驗證、落地、清理 |
| `/10x:audit` | 對指定範圍（diff、路徑或整個 repo）執行已安裝的 Cloudflare `security-audit` skill，把結果合併進 `.10x/security.md`，重跑時不會重複分流同一個問題；再逐一和你確認每個新的或延後的項目，並為每個 `fix-now` 開一張本機 ticket |
| `/10x:roadmap` | 把需求排進 `.10x/roadmap.md` 的版本裡，每個版本寫明排在這裡的理由，你核准後才寫入；可以把一個版本的每個項目各開成一張 ticket，交給 `/10x:batch <version>` 處理並標成 `Done`。也會把 `.10x/security.md` 裡延後處理的 `confirmed` 項目列為需求；每張 security ticket 怎麼開由 `10x-security route` 決定：`tickets: files` 開本地 ticket，private repo，或尚未釋出或嚴重度低的項目，開 issue，public repo 裡已釋出且 `medium` 以上的項目則開 draft security advisory 加本地 ticket，絕不開公開 issue。`show` 最後會建議發版前先跑 `/10x:audit <tag>..HEAD` |
| `/10x:batch` | 在同一個 terminal 處理多張 ticket，每張在背景 worker 裡完成 |
| `/10x:commit` | 只 commit 這個 session 改過的路徑，訊息照 repo 自己的風格。會直接 commit，只有疑似 secret、範圍不清楚或有不相關的改動時才停下來問。說「message only」就只給草稿 |
| `/10x:code-review` | 審查還沒 commit 的改動 |
| `/10x:code-review-branch` | 審查整個 branch 相對於 base 的改動 |

skills 用到的 script 見 [docs/scripts.md](docs/scripts.md)（英文）。

### Hooks

| Hook | 用途 |
|---|---|
| Guard | 擋下破壞性的 Bash 指令（`rm -rf`、force push、`git reset --hard`…） |
| Context gate | session 已經太大時，拒絕執行 `/10x:work` 和 `/10x:close` |
| Stop gate | 還有驗收條件沒交代清楚時，不讓 session 結束 |
| Grant | 你輸入的流程 skill，其授權在整個 session 內都有效 |

細節見 [docs/hooks.md](docs/hooks.md)（英文）。

## 安全與權限

- **Guard 只是盡力而為，不是 sandbox。** 它比對的是指令文字，所以 script、alias 或 `eval` 都能繞過。
- **公開寫入一律會問。** 建立 issue 或 security advisory、貼規劃留言都不在任何 skill 的 `allowed-tools` 裡，所以就算你已經核准草稿，每次還是會跳出權限詢問。在 auto mode 下則由分類器決定，不會跳出詢問。
- **寫入只吃 ticket id。** push、開 PR、合併 PR 都經過 `10x-land`，它只用 ticket id 組出每個指令，所以不應該在設定裡允許 `gh pr merge` 或 `git push`。
- **授權只在你輸入 skill 的那個 session 有效。** [Grant hook](docs/hooks.md#grant) 只放行符合該 skill 授權的單一指令，subagent 裡不適用，而 10x Agent 的 script 只能用在你輸入 skill 時指定的那張 ticket。
- **有些 script 會執行專案的程式碼。** `10x-verify`、`10x-red-proof`、`10x-test` 和 `10x-worktree add` 會跑專案的 gates、setup 和測試，所以授權它們，等同於讓 agent 可以寫入 repo 裡的檔案。

## 授權

10x Agent 以 [MIT License](LICENSE) 授權釋出。

10x Agent 這個名稱指的是本專案；請不要用它命名 fork 或衍生作品，但說明某個 fork 是基於 10x Agent 是可以的。
