# Security policy

## Reporting a vulnerability

Report a vulnerability in 10x Agent privately, through GitHub's private vulnerability reporting:

https://github.com/minanyang/10x-agent/security/advisories/new

Do not open a public issue for it. `/10x:feedback` follows the same rule: a report it classifies as a vulnerability files no public issue and gives you this URL and the draft to paste there instead.

A vulnerability here is a way to cross a boundary 10x Agent sets: a batch worker escaping its sandbox or writing a file it is denied, a grant allowing a command it does not name, a script writing outside the paths it is given, or a secret reaching a public place.
