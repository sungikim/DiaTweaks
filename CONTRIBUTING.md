# Contributing

Keep it small, test it hard, show it working.

## Pull requests

- One change per PR.
- Fill in the template: What, Why, Proof, Tested on, Checklist. Short sentences.
- Never leave a section empty or delete it. If one doesn't apply, write `N/A` in it, and tick a checklist item that doesn't apply with `(N/A)` after it. Proof is never N/A for a change you can see in Dia.
- Proof is required for anything visible in Dia: a screenshot for static changes, a screen recording for anything that animates. Show before and after when you change existing behaviour.
- Try to break what you made before you open the PR, and fix what you find. Every change has to work with tabs in the sidebar and tabs at the top, and with each tweak on and off.
- Build with `make` and run it on your own Dia with `./install.sh`.

## Adding a patch

- Put its `DPPatch` in a new `src/dylib/Patches/*.m`, declare it in `DiaPatches.h` and add it to `DPPatches[]` in `DiaPatches.m`.
- List the Dia classes it relies on in `.classes`. On a Dia version without one of them, the patch stays off and Settings shows it as unavailable.
- Give it a `.verify` that looks at Dia's views and returns `nil` when they match `on`, or a few words saying what's wrong. Find the views with `DPFindViews`, not through your own hooks, so a hook that never ran shows up as a failure.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org): `fix(dylib): keep the top padding under horizontal tabs`.
- Imperative, lowercase, under 72 characters. Add a body only if the diff would mislead without it.
- No tool or AI attribution trailers (`Co-authored-by: Claude`, `Generated with …`).

## AI tools

Use whatever tools you like. You're responsible for what you submit: it has to work, and you have to have tested it yourself.

No slop: no padded descriptions, generated summaries or filler ("comprehensive", "robust", "seamless", "this PR introduces…"). PRs that read like unchecked AI output are closed without review.

## Never

- Commit Dia itself or anything from its bundle.
- Sign with, or ship, anyone else's certificate.
