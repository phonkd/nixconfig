# Local HF agent skill

**Repos:** HF and nixconfig  **Status:** done

## Goal
Make the HF course-file retrieval skill available to new agents through Home Manager without requiring private GitHub access or a checkout during rebuilds.

## Approach
Keep the skill and school-session helper in the private HF repository, cloned separately to `~/git/HF`. A module in nixconfig uses native `home.file` and `mkOutOfStoreSymlink` to link `~/.codex/skills/hf-teams` to the local checkout. It never imports or fetches HF and never reads cookies into the Nix store. A missing checkout leaves a dangling skill link, not an evaluation dependency.

## Steps
- [x] Package and validate the skill, source-reference handoff, helper and tests in HF (six tests and live school access pass).
- [x] Published `https://github.com/phonkd/HF` and verified private visibility. Local checkout is `~/git/HF`; `main` tracks `origin/main`.
- [x] Add the HF Home Manager module to GUI configurations; commit only these changes to local main.
- [x] Check Nix syntax and module references; inspect native Home Manager symlink handling for missing targets.
- [x] Verified the active Home Manager skill link on `blac`: `~/.codex/skills/hf-teams` resolves through the Home Manager generation to `~/git/HF/skills/hf-teams`. Activation was completed outside the agent run.

## Rollout
Use the existing native Home Manager file mechanism. No custom activation script, flake input, Git fetch, token, cookie, or coursework enters nixconfig. Removing the module import removes the managed link; the private checkout remains untouched. Do not deploy other hosts as part of this change.
