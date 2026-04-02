# 📦 move2modern.co.uk — Script Library

> **Real-world PowerShell for Microsoft 365 & Intune professionals.**
> Every script in this repo was written and tested and links to a specific Blog or solution created by [move2modern.co.uk](https://move2modern.co.uk). 

---

## 🗂️ What's in here?

This repository is the companion script library for the **move2modern.co.uk** blog site. Each folder maps directly to a blog post or solution created and will be linked to by the blog or website. You'll find everything you need to follow along, adapt, or just grab what you need and run.

Scripts are organised by topic. Clone the whole repo or drill straight into the folder you need.

```
move2modern-scripts/
│
├── intune-utcm-drift/          ← Intune & UTCM configuration drift series
│   ├── Part1/
│   └── Part2/
│
└── ...                         ← More folders added as new posts are published
```

---

## 🚀 Getting Started

### Clone the repo

```powershell
git clone https://github.com/move2modern/blog-scripts.git
cd blog-scripts
```

### Or download a single folder

Don't need the whole repo? Use [DownGit](https://minhaskamal.github.io/DownGit) to grab just the folder you want — paste in the GitHub folder URL and it'll zip it up for you.

---

## 📋 Prerequisites

Most scripts in this repo target **Microsoft 365 and Intune** environments and share a common set of requirements:

| Requirement | Notes |
|---|---|
| PowerShell 7.x | Recommended for all scripts |
| Microsoft.Graph PowerShell SDK | `Install-Module Microsoft.Graph` |
| Appropriate M365 permissions | Documented per script/folder |
| Az PowerShell module | Required for Azure Automation scripts |

> ⚠️ **Always review a script before running it in production.** These are provided as-is and intended as a learning resource alongside the blog post. Test in a non-production tenant first.

---

---

## 📁 intune-utcm-drift — Configuration Drift Management

> **Blog series:** [Intune Configuration Drift Management](https://move2modern.co.uk)
> Microsoft 365 & Intune | Entra ID | Azure Automation | SharePoint

### Part 1 — Intune Alternative approaches to UTCM:

Alternative an d available solution approaches to drift managwment  — no UTCM required.
📖 Read the post: *[[Link to Part 1](https://move2modern.uk/index.php/2026/03/08/alternative-approaches-to-utcm/)]*

---

### Part 2 — UTCM (Unified Tenant Configuration Management) Drift Monitoring

Scripts built around Microsoft's **UTCM Graph API** (March-April 2026). These were tested against real tenants in March 2026 — findings and caveats are documented in the blog post and inline in each script.

| Script | Purpose |
|---|---|
| `Setup-UTCMBaseline.ps1` | Idempotent tenant setup — provisions the UTCM service principal, assigns permissions, and creates the baseline CA monitor |
| `Get-UTCMDriftResults.ps1` | Queries active drift results and logs them to a SharePoint list |
| `Reset-UTCMCABaseline-Runbook.ps1` | Azure Automation runbook — detects drift via SharePoint and hands off to the manual reset script |
| `Reset-UTCMCABaseline-Manual.ps1` | Interactive delegated-auth script — resets the UTCM CA baseline (UTCM write operations require delegated auth, not Managed Identity) |

📖 Read the post: *[Link to Part 2]*

#### ⚡ Quick reference — UTCM service principals

| Service Principal | App ID | Role |
|---|---|---|
| Unified Tenant Configuration Management | `03b07b79-c5bc-4b5e-9bfa-13acf4a99998` | Does the actual monitoring work |
| M365 Admin Services | `6b91db1b-f05b-405a-a0b2-e3f60b28d645` | Required Microsoft co-dependency — provision if missing |

> 🔬 **Personal observations:** UTCM is in staged public preview. The resource type findings in Part 2 reflect testing against `andy@move2modern.co.uk` and `kumonix.com` in March 2026. Your results may vary — especially for resource types outside the confirmed working tier.

---

---

## 🤝 Usage & Licence

Scripts are published for **educational purposes** to accompany blog posts on [move2modern.co.uk](https://move2modern.co.uk).

- ✅ Free to use, adapt, and build on
- ✅ Attribution appreciated — link back to the post if you share
- ❌ Not a supported product — no warranties, no SLAs

---

## 💬 Feedback & Issues

Found a bug? Something not working in your tenant? Head over to the blog post comments, or raise an [issue](https://github.com/move2modern/blog-scripts/issues) here on GitHub.

---

*Built and maintained by [Andy Jones](https://move2modern.co.uk) — Microsoft 365 & Intune consultant.*
