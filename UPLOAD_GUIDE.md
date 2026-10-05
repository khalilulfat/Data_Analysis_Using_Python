# How to publish your portfolio on GitHub

This folder holds **four repositories** - one per sub-folder:

| Folder | GitHub repository name | What it is |
|---|---|---|
| `YOUR-USERNAME/` | **exactly your GitHub username** | Your profile page README |
| `olist-delivery-analytics/` | `olist-delivery-analytics` | Python data-analysis project |
| `sqlserver-logistics-inventory-db/` | `sqlserver-logistics-inventory-db` | Large SQL Server database |
| `sqlserver-marine-spares-db/` | `sqlserver-marine-spares-db` | Compact SQL Server database |

Allow about 30 minutes.

---

## Step 1 · Personalise the placeholders

Use your editor's **"Replace in files"** (VS Code: `Ctrl+Shift+H`) across the whole folder:

| Replace | With | Example |
|---|---|---|
| `YOUR-USERNAME` | your GitHub username | `jsmith-data` |
| `YOUR NAME` | your full name | `Jane Smith` |
| `YOUR-LINKEDIN` | the end of your LinkedIn URL | `jane-smith-123` |
| `YOUR-EMAIL` | your email address | `jane@example.com` |

Then **rename the folder** `YOUR-USERNAME` to your actual username.

> The CI badges in the READMEs only work once `YOUR-USERNAME` is replaced with your real username.

---

## Step 2 · Install Git (one-off)

- Windows / macOS: install **[GitHub Desktop](https://desktop.github.com/)** (easiest), or Git from <https://git-scm.com>.
- Sign in with your GitHub account.

> ⚠️ Avoid drag-and-drop upload in the browser for these projects: it often skips the hidden `.github` folder, which
> contains the automated tests that make the green badges work.

---

## Step 3 · Create and upload each repository

Repeat for each of the four folders.

### Option A - GitHub Desktop
1. **File → Add local repository →** choose the folder → when asked, click **"create a repository"**.
2. Keep the name exactly as in the table above. Leave *Initialize with README* **unticked**.
3. Click **Commit to main** (summary: `Initial commit`).
4. Click **Publish repository** → **untick "Keep this code private"** → **Publish**.

### Option B - command line
Create an **empty public** repository on github.com first (no README, no licence), then:

```bash
cd olist-delivery-analytics            # the folder you are uploading
git init -b main
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/YOUR-USERNAME/olist-delivery-analytics.git
git push -u origin main
```

The Olist data files are 0.1-15 MB each, well within GitHub's 100 MB per-file limit.

---

## Step 4 · Check the automated builds

Open each project's **Actions** tab on GitHub. A run starts automatically after the first push:

| Repository | What the workflow does | Typical time |
|---|---|---|
| olist-delivery-analytics | installs Python packages and executes all 5 notebooks | ~5 min |
| sqlserver-logistics-inventory-db | starts SQL Server 2022 in a container and runs the full build script | ~3 min |
| sqlserver-marine-spares-db | same, for the smaller database | ~2 min |

✅ Green tick = it works, and the badge in the README turns green.
❌ Red cross = open the run, copy the error message, and fix it (or ask for help with the exact message and line number).

> The Python notebooks were executed end to end before packaging (on pandas 2.2 and 3.0). The SQL scripts were written for
> SQL Server 2019+ but could not be executed on SQL Server while being built - the workflow is their first real run, so check it.

---

## Step 5 · Polish your profile

1. **Profile README:** the repository named after your username appears automatically at the top of your profile.
2. **Pin your projects:** profile → **Customize your pins** → select the three projects.
3. **Describe each repository:** on its main page click the ⚙️ next to **About**, add a one-line description and topics, e.g.
   - Olist: `data-analysis` `python` `pandas` `machine-learning` `logistics` `nlp`
   - SQL projects: `sql-server` `t-sql` `database-design` `stored-procedures` `inventory-management`
4. Add a profile photo and a one-line bio.

---

## Optional · Run things locally

**Python project**
```bash
cd olist-delivery-analytics
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
jupyter lab
```

**SQL projects** - open the `*_Complete.sql` file in SQL Server Management Studio and press **F5**.
