# Contributing

Thanks for helping! This tool protects people's GitHub accounts, so every
change keeps the same high bar for safety and simplicity.

## Ground rules

1. **No network calls, no telemetry, no `eval`.** `scripts/check-policy.sh`
   enforces this.
2. **No new dependencies.** The tool uses only what ships with macOS: bash
   3.2, `plutil`, `codesign`, `open`, `rsync`.
3. **Never touch tokens or the user's `~/.gitconfig`.**
4. **Quote every path**, validate every input, and never write through a
   symlink.
5. **Every change comes with a test.** A security fix also gets an "attack
   test" that repeats the attack.
6. **Plain, friendly messages.** Every error says what went wrong and the
   next step.

## Set up your clone

```bash
git config core.hooksPath .githooks   # pre-commit secret and policy check
brew install shellcheck bats-core gitleaks
```

## Check your change

```bash
bash scripts/check-policy.sh
shellcheck -x --shell=bash --severity=style mac/ghdp tests/mac/ghdp.bats \
  install-mac.command uninstall-mac.command scripts/check-policy.sh .githooks/pre-commit
bats tests/mac
```

The tests use a throwaway home folder and never touch your real setup. Tests
that need GitHub Desktop are skipped when it is not installed.

## Pull requests

- Keep them small and focused, with a clear description of the why.
- Update `README.md` and `CHANGELOG.md` when behaviour changes.
- CI must be green.

## Security problems

Please do **not** open a public issue. See [SECURITY.md](SECURITY.md).
