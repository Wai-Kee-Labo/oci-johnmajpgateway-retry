# OCI Always Free retry — JohnMaJPGateway (GitHub Actions)

每 6 小時自動跑一次，每次最多跑 330 分鐘，每 60 秒試開機一次，
直到成功、時間到（下一個排程會自動續跑）、或者撞到非 capacity error 為止。

定稿規格（寫死喺 workflow 同 script 入面，唔好改）：
- 機名：JohnMaJPGateway
- Region：ap-osaka-1，大阪，唯一 AD-1
- Shape：VM.Standard.A1.Flex，2 OCPU / 12 GB
- OS：Canonical Ubuntu 24.04 ARM（非 Minimal，自動搵最新一個）
- VCN：JohnMaJPGatewayVCN（重建後嗰個），public subnet，public IPv4 = Yes
- Boot volume：default，唔加額外 volume
- Security list：完全唔郁。Public ingress 而家封晒，
  所以就算開到機，**由出面 SSH 入去都會入唔到**，直到加返 SSH rule 為止。

## 重要：Public vs Private repo 嘅分鐘數

呢個係成個做法最關鍵嘅取捨，開 repo 之前一定要揀好：

- **Public repo：GitHub Actions 標準 runner 分鐘數無限**，24 小時連續跑都唔使錢。
  代價係 repo 入面嘅 code 會公開 — 但呢個 repo 入面**只有機名、region、
  VCN 名呢類非敏感資料，冇任何 OCID、冇任何 key**，所有敏感嘢都只係
  存喺 Secrets 入面，唔會入 code、唔會出 log。
- **Private repo：GitHub Free 每個月得 2,000 分鐘**，連續跑一日已經用晒
  約 1,440 分鐘，即係大約一日半就會用爆，之後要付費先跑得落去
  （Linux runner 超出部分約 $0.006/分鐘），或者等下個月 reset。

所以長時間 24 小時搶機，**Public 先係實際可行嘅免費做法**；
Private 只適合「試幾日、肯付費」或者「已經有 Pro/Team/Enterprise」
嘅情況。Repo  visibility 隨時可以喺 Settings 改返，但改返 Private
之後分鐘數限制就會即刻生效。

## 開 repo 之後要做嘅 3 步

### 1. 喺 OCI Console 開 API Key（同之前 Mac 版一樣，唔好喺 chat 貼）

Profile → My Profile → API Keys → Add API Key → Generate API key pair
→ Download private key。抄低 tenancy OCID、user OCID、fingerprint、
region（ap-osaka-1）。

### 2. 為部機 generate 一對新 SSH key（同 API key 係兩樣嘢）

```bash
ssh-keygen -t ed25519 -f ~/.ssh/oracle-johnmajpgateway
```

Workflow 只需要 `.pub` 嗰行（public key），private key 你自己保管，
**永遠唔好放入 GitHub、唔好貼去 chat**。

### 3. 喺 GitHub repo 入面加 Secrets

Repo → Settings → Secrets and variables → Actions → New repository secret，
逐個加（名要一字不差）：

| Secret 名 | 內容 |
|---|---|
| `OCI_USER_OCID` | OCI user OCID（`ocid1.user...`） |
| `OCI_TENANCY_OCID` | Tenancy OCID（`ocid1.tenancy...`，同時係 root compartment） |
| `OCI_FINGERPRINT` | API key fingerprint（Console 顯示嗰個） |
| `OCI_REGION` | `ap-osaka-1` |
| `OCI_PRIVATE_KEY` | API key 嘅 private key **全文**，包括 `-----BEGIN PRIVATE KEY-----` 同 `-----END PRIVATE KEY-----` 嗰幾行 |
| `OCI_SSH_PUBLIC_KEY` | Instance SSH public key 嗰一行（`ssh-ed25519 AAAA...`） |

加完之後，去 Actions → OCI Always Free retry → Run workflow → Run workflow，
手動跑一次驗證；之後每 6 小時會自動排程跑。

## 成功之後點做

1. Actions 個 run 會顯示 SUCCESS，同埋部機嘅狀態同 public IPv4。
2. 去 OCI Console → Compute → Instances（大阪）睇 JohnMaJPGateway，
   等狀態變 RUNNING。
3. **加返 SSH rule 先入到機**：Networking → JohnMaJPGatewayVCN
   → Default Security List → Add Ingress Rules，Source 填你自己嘅 IP
   （最穩陣，唔好直接開 0.0.0.0/0），Destination Port 22，TCP。
4. 入機（`ubuntu` 係 Ubuntu image 預設用戶）：

```bash
ssh -i ~/.ssh/oracle-johnmajpgateway ubuntu@<public IPv4>
```

## 點停低

- 暫停排程：Actions → workflow → Disable workflow，或者刪咗個 workflow。
- 永久停：刪 repo，或者刪晒 Secrets（冇 Secrets 嘅 run 會即刻 fail，唔會開機）。
- 成功開機之後，之後嘅排程 run 會 check 到同名機已經存在，即刻退出，
  唔會開重複機 — 但為咗慳分鐘數，成功之後都應該手動 Disable workflow。

## 安全提醒

- 呢個 repo 入面唔應該出現任何 OCID、fingerprint、private key。
  如果你唔小心 commit 咗，**即刻去 OCI Console revoke 嗰把 API key**，
  再喺 GitHub 刪 history，唔好只係改返個 file。
- API key 應該只俾呢個用途用，成功開機之後可以 revoke 佢，
  之後要管理部機就用 instance SSH key。
