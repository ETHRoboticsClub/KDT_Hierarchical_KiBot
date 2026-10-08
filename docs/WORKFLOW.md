# Team workflow: KiCad 9 + Git + KiBot CI

## Branch model

```
main      ●───────────────────────●  tag 1.0.0 → release
           \                     /
dev         ●──●─────●─────●────●   integration; CI commits "Update Outputs"
                \   /       \  /
feature/a        ●─●         \/      owner: Alice  (Section A sheet only)
feature/b         ●──●──●───●        owner: Bob    (Section B sheet only)
```

| Branch | Who edits what | CI on push | Pull after CI? |
|---|---|---|---|
| `feature/<name>` | **one** owner, only the files listed for `<name>` in `.github/sheet-ownership.conf` | ownership guard, ERC, schematic PDF as downloadable artifact | **No** (CI commits nothing) |
| `dev` | integrator: root/parent sheets, `.kicad_pro`, net classes, new sheets | full KiBot outputs, committed back | **Yes**, before your next push to dev |
| `main` | nobody directly; PR from dev, then tag | release outputs | yes |

## Why this keeps merge conflicts down

* Every KiCad sheet is its own `.kicad_sch` file. If each branch only touches its own sheet file, Git merges branches without conflicts. The guard enforces this.
* Generated files (PDFs, gerbers, README) are only committed on `dev`/`main`. Feature branches never contain them, so two features can't conflict on binary PDFs.
* The `.kicad_pro`, root sheet, parent sheets (which hold the sheet symbols and sheet pins) and the `.kicad_pcb` are shared. Only the integrator changes them, on `dev`.
* `.kicad_prl` (your personal view state) is git-ignored.

## One-time setup (Ubuntu 24.04)

```bash
sudo add-apt-repository ppa:kicad/kicad-9.0-releases
sudo apt update && sudo apt install kicad git
git config --global user.name  "Your Name"
git config --global user.email "you@example.org"
git config --global pull.rebase false     # pull = merge (simplest for KiCad files)
git clone git@github.com:<org>/<project>.git && cd <project>
mkdir -p ~/.local/share/fonts && cp -i kibot_resources/fonts/*.ttf ~/.local/share/fonts/ && fc-cache
cp -i kibot_resources/colors/Altium_Theme.json ~/.config/kicad/9.0/colors/
```

## One "instance" on your feature branch

```bash
# 0. KiCad closed!
git switch feature/power-gen
git pull                                  # get your own latest state
git merge origin/dev                      # optional: pick up integrated work (do it at least weekly)

# 1. change: open the project in KiCad, edit ONLY your sheet, save, CLOSE KiCad
# 2. stage: add your files by name, never "git add -A"
git status
git add "Power - Generation.kicad_sch"
# 3. commit
git commit -m "power-gen: add 5V buck stage"
# 4. push
git push
# 5. check: GitHub → Actions → your run. Green = guard + ERC ok.
#    Download the "schematic-check-N" artifact for the PDF and ERC report.
#    Nothing to pull back on a feature branch.
```

## Rules inside KiCad

1. **Close KiCad before any `git pull / merge / switch`.** KiCad does not reload files changed on disk, and saving afterwards silently overwrites what you pulled.
2. **Edit only your sheet.** Do not move or edit sheet symbols or sheet pins in the parent sheet; ask the integrator.
3. **Annotate: scope "Current sheet only"**, numbering "first free after sheet number × 100" (Alice's sheet 3 gives R301, R302 …). Never "Annotate entire schematic" on a feature branch.
4. **Hierarchical labels** are yours (child sheet). The matching **sheet pins** are the integrator's (parent sheet, "Sync Sheet Pins" on dev after your PR is merged).
5. If KiCad shows `.kicad_pro` or `.kicad_pcb` as modified in `git status`, **don't commit them**: `git restore <file>`.
6. Project symbol libraries: one `.kicad_sym` per feature (`lib/lib_sym/power_gen.kicad_sym`), listed in the mapping file. Footprints in `*.pretty/` are one file each and never conflict.

## Getting your work into dev

1. Open a PR `feature/<name>` → `dev`. Check the base branch: GitHub's
   "Compare & pull request" banner targets the repo's **default branch**. Set
   `dev` as the default branch (Settings → General) so a feature can't land
   in `main` by accident.
2. Checks: *Sheet ownership guard* and *Schematic check* must be green.
3. Merge with **"Create a merge commit"** (not squash: feature branches live long, and squash makes the next PR from the same branch conflict).
4. CI on dev regenerates all outputs (~ minutes). Then everybody: `git switch dev && git pull`.

## Integrator tasks (on dev, KiCad closed for everyone else on dev)

* **New feature:** create the empty sheet + sheet symbol in the parent, add `name = file` to `.github/sheet-ownership.conf` (and CODEOWNERS), push to dev, then `git switch -c feature/<name> origin/dev && git push -u origin feature/<name>`.
* **Interface change:** after a feature PR adds hierarchical labels, sync the sheet pins in the parent sheet on dev and wire them.
* **Project settings** (net classes, ERC severities, text variables): `.kicad_pro` changes on dev only.
* **PCB:** one layout person at a time, either on dev or on `feature/layout` (mapping `layout = *.kicad_pcb`). After merging dev: *Tools → Update PCB from Schematic*.

## "Only one person per sheet at a time"

Git cannot lock text files. We use:

* the branch owner: the GitHub issue for the feature is **assigned** to whoever currently holds it;
* handoff = holder pushes, waits for green CI, reassigns the issue; the new holder pulls;
* the ownership guard (blocks edits of other people's sheets) and CODEOWNERS review on PRs into dev.

## Releasing (unchanged from the template)

PR `dev` → `main`, then `git switch main && git pull && git tag 1.0.0 && git push origin 1.0.0`, then `git switch dev && git merge main`.

What the tag run does, in order: commits the CHANGELOG (`[Unreleased]` becomes
`[1.0.0]`) to main, builds everything with the RELEASED variant (ERC must be
clean, DRC only reports), commits "Update Outputs (release)" to main and
creates the GitHub release with the PDFs, Gerbers, ODB++, STEP, BoM and
pick-and-place as assets. That commit also contains the `.kicad_pcb` (stackup
drawing, saved in KiCad 9 format) and the `.kicad_pro` (filled-in notes and
text variables): merge main back into dev right away, before anyone touches
the PCB. Write real entries under `[Unreleased]` in `CHANGELOG.md` before
tagging; they become the release notes.

The board needs an outline and at least one hole for a release, otherwise the
fabrication PDF cannot be built.
