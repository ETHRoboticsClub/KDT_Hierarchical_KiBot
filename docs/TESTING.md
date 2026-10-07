# Testing the workflow (Ubuntu 24.04)

Use the template's own schematic as the dummy project: it already has
hierarchical sub-sheets (`Section A`, `Section B` under `Project Architecture`,
`Power - Sequencing` under the root), and `sheet-ownership.conf` maps them.

## 0. Tools

```bash
sudo add-apt-repository ppa:kicad/kicad-9.0-releases
sudo apt update && sudo apt install -y kicad git shellcheck
# GitHub CLI (optional, handy for watching runs)
sudo apt install -y gh && gh auth login
# actionlint (workflow linter)
curl -sSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz \
  | tar xz actionlint && sudo mv actionlint /usr/local/bin/
```

## 1. Static checks (seconds, before every push of CI changes)

```bash
actionlint .github/workflows/ci.yaml
shellcheck .github/scripts/check_sheet_ownership.sh
FEATURE_BRANCH=feature/section-a bash .github/scripts/check_sheet_ownership.sh   # on a feature branch
```

## 2. Dummy project from the adjusted template

Don't test in a real project repo. Make a throw-away project from this
template branch and give it its own repo in the org (public = unlimited
Actions minutes and branch rulesets on the Free plan).

```bash
# 2a. Install the adjusted template into KiCad 9's user template folder
mkdir -p ~/.local/share/kicad/9.0/template && cd ~/.local/share/kicad/9.0/template
git clone -b ci/multi-user-workflow git@github.com:ETHRoboticsClub/KDT_Hierarchical_KiBot.git
mkdir -p ~/.local/share/fonts && cp -i KDT_Hierarchical_KiBot/kibot_resources/fonts/*.ttf ~/.local/share/fonts/ && fc-cache
mkdir -p ~/.config/kicad/9.0/colors && cp -i KDT_Hierarchical_KiBot/kibot_resources/colors/Altium_Theme.json ~/.config/kicad/9.0/colors/
```

2b. In KiCad: **File → New Project From Template → KDT_Hierarchical_KiBot**,
name it e.g. `ci_dummy`, in `~/ci-test/ci_dummy/`. Close KiCad.

2c. KiCad does **not** copy hidden files from a template on Linux. Copy them
yourself, then make it a repo with `main` and `dev`:

```bash
T=~/.local/share/kicad/9.0/template/KDT_Hierarchical_KiBot
cd ~/ci-test/ci_dummy
cp -r "$T/.github" "$T/.gitignore" "$T/.gitattributes" .
cp -rn "$T/docs" .                       # in case KiCad skipped it
ls "Section A - Title A.kicad_sch" "Section B - TItle B.kicad_sch"   # sub-sheets keep their names
rm -rf .git                               # in case KiCad copied the template's history
git init -b main && git add -A && git commit -m "Dummy project from template"
git switch -c dev
# create the empty repo ETHRoboticsClub/kicad-ci-sandbox on GitHub first (no README), then:
git remote add origin git@github.com:ETHRoboticsClub/kicad-ci-sandbox.git
git push -u origin main dev
```

What to check after renaming:

* `.github/sheet-ownership.conf`: the three sub-sheet entries still match (KiCad only renames the root files to `ci_dummy.*`). If you add your own sheets, add a line per feature.
* `.github/CODEOWNERS`: optional for the test; rules are commented out.
* `kibot_yaml/kibot_main.yaml`: `GIT_URL` points to the template repo; set it to the sandbox URL (it only appears in the generated docs).

GitHub settings of the sandbox:

* **Actions → General → Workflow permissions:** "Read and write". If the org forbids it, the dev output commit fails with 403 (T6).
* **Secrets and variables → Actions → Variables:** none needed (defaults: `KIBOT_VARIANT=DRAFT`, `ERC_BLOCKING=false`, `SHEET_GUARD_MODE=fail`).
* **Rules → Rulesets** (later, T8): ruleset on `dev`: require PR, required checks *Sheet ownership guard* and *Schematic check (ERC + PDF artifact)*.

The first push of `dev` already runs CI: wait for the "Update Outputs" commit
before cloning (step 3).

## 3. Simulate two users on one machine

```bash
cd ~/ci-test
git clone git@github.com:ETHRoboticsClub/kicad-ci-sandbox.git alice
git clone git@github.com:ETHRoboticsClub/kicad-ci-sandbox.git bob
git -C alice config user.name Alice && git -C alice config user.email alice@example.org
git -C bob   config user.name Bob   && git -C bob   config user.email bob@example.org
git -C alice switch -c feature/section-a origin/dev && git -C alice push -u origin feature/section-a
git -C bob   switch -c feature/section-b origin/dev && git -C bob   push -u origin feature/section-b
```

Open `alice/ci_dummy.kicad_pro` in KiCad for Alice's edits and
`bob/ci_dummy.kicad_pro` for Bob's. Close KiCad between users. Leave the
original `~/ci-test/ci_dummy` folder alone after step 2 (or delete it), so you
don't push from three places.

## 4. Test cases

| # | Do | Expect |
|---|---|---|
| T1 | Alice: add a resistor in *Section A*, annotate current sheet only, commit just that file, push | guard ✅, ERC step runs, artifact `schematic-check-N` contains a schematic PDF showing the resistor. **No** commit from CI on `feature/section-a` |
| T2 | Bob (in parallel): same in *Section B*, push | same as T1 |
| T3 | Both open PRs into dev, merge Alice's, then Bob's (within ~1 min) | Bob's PR merges **without conflicts**. The first dev run notices dev moved and does not push; only the second commits "Update Outputs" |
| T4 | Alice: edit *Section B* too, push | guard ❌, annotation on the file name in the run summary |
| T5 | Alice: change a net class (touches `.kicad_pro`), push | guard ❌ (shared file) |
| T6 | After T3: Bob pushes to dev **without** pulling | push rejected (non-fast-forward). `git pull` merges cleanly (only outputs changed), push works |
| T7 | Push two commits to dev 30 s apart | second run waits (concurrency); first run logs "Outputs not pushed … branch moved"; only one "Update Outputs" commit lands |
| T8 | Enable the dev ruleset (require PR) | **Expected failure**: CI can't push "Update Outputs" to dev. Fix: add the bypass actor (or deploy key) for CI, or require PRs only on main. Re-run T3 |
| T9 | Alice and Bob both edit *Project Architecture* (parent sheet) on dev | real Git conflict: demonstrates why parent sheets belong to the integrator |
| T10 | Both annotate with "entire schematic" (both get R1), open a PR into dev | Git merges cleanly. KiCad's CLI ERC does **not** see it; the *Duplicate / unannotated references* step reports R1 on both sheets (warning, or ❌ with `ERC_BLOCKING=true`) |
| T11 | Push a feature with an unconnected pin; then set `ERC_BLOCKING=true` and re-run | First: job ✅ with an ERC warning and a `KiBot: kibot_erc.log` annotation naming the pin. Then: Schematic check ❌ |
| T12 | PR dev → main, merge, `git tag 0.1.0 && git push origin 0.1.0` | release with assets; `CHANGELOG.md` gets a `0.1.0` section; then `git switch dev && git merge origin/main` |

Pass = T1–T7, T11, T12 behave as expected and you understood T8–T10.

Notes from the first sandbox run (Oct 2026):

* A brand-new project has no board outline and no drill holes. KiBot then
  writes no drill table and cannot configure the fabrication PDF, so the
  README step is skipped with the warning *README.md not updated* until the
  board has holes. Schematic outputs are unaffected. A release (T12) needs a
  board with an outline and at least one hole.
* Failed KiBot steps post their errors as annotations on the run and on the
  PR's checks tab; you rarely need to download the log artifacts.
* Every dev push produces an "Update Outputs" commit, even without design
  changes: KiBot stamps the commit hash and date into the PDFs and netlist.
* PRs into main run no checks: their head is always a bot commit, which
  GitHub only runs after a manual "Approve and run".

## 5. Optional: run KiBot locally (Docker)

```bash
sudo apt install -y docker.io && sudo usermod -aG docker $USER   # log out/in once
./kibot_resources/scripts/docker_kibot_linux.sh -v 9
# inside the container:
./kibot_launch.sh -v DRAFT
```

Useful to debug KiBot config errors without waiting for Actions. Don't commit
locally generated outputs; CI owns them.

## 6. Moving to the real project

Once this branch is merged into the template's `main`, new projects get
everything via **New Project From Template** (plus the hidden-file copy in
2c). For an existing project, copy `.github/`, `.gitignore`, `.gitattributes`,
`docs/` into its repo on dev, rewrite `sheet-ownership.conf` and `CODEOWNERS`
for your sheets, push, and re-run T1 and T3 once with real people.
