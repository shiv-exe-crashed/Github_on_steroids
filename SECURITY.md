# Security policy

This tool helps people keep their GitHub accounts apart, so security
problems matter a lot. Thank you for reporting them carefully.

## How to report a problem

- **Please do not open a public issue** for a security problem.
- Use GitHub's private reporting instead: on this repository, open the
  **Security** tab and choose **Report a vulnerability**.
- **Never include a real token, password or private key in a report.** If you
  found one, describe where it was and what kind it was, not the value.
- Say what you did, what you expected, what happened, and your OS version and
  GitHub Desktop version.

## What happens next

- You get a first reply within 7 days. This is a small volunteer project, so
  it is best effort.
- We confirm the problem, fix it, add a test that repeats the attack, and
  credit you in the changelog if you want.

## What is in scope

- The scripts in this repository: `mac/ghdp`, the double-click installers,
  the generated launchers and guard hooks, and the CI workflow.
- Problems in **GitHub Desktop itself** belong to GitHub. Report them through
  GitHub's bug bounty program, not here.

## How this tool is built to be safe

- [THREAT_MODEL.md](THREAT_MODEL.md): what we protect, who might attack, each
  defence, and the honest limits.
- [docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md): our own attacker-style
  review, what it found, and how each finding was fixed.
- In short: the tool never reads, stores, prints or sends tokens or
  passwords; makes no network calls; needs no admin rights; checks GitHub
  Desktop's signature before every launch; and has no third-party
  dependencies at run time.
