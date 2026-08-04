# docs/plans/

Working and planning history. Never loaded by the plugin at runtime, exempt
from `test/zero-source-grep.sh`'s SOURCE-GREP scan alongside `docs/design/`,
and free to be in French, per the root `CLAUDE.md`.

These files were kept out of git until 2026-08-04 and lived only on the
maintainer's disk. That was the one place they could be lost, and the friction
log below is the highest-value artifact this repository has produced from real
use, so they are tracked now.

**This index is the only place a status is recorded.** Do not stamp a status
header into the files themselves: two places to keep in sync is how a
derivative drifts from its source, which this repository has demonstrated more
than once.

| File | Status | What it is |
|---|---|---|
| `2026-08-03-friction-log-tapelibrary.md` | **active** | Defects found by using the plugin to build a real exporter, recorded live rather than reconstructed. Six plugin defects so far, plus a correction on metric naming. **Fill it during the session, not after.** |
| `NEXT-PROMPT-field-defects.md` | **pending** | The four groups of defects the friction log produced, ordered by value over cost: the TLS/proxy gaps, the naming questions `/add-collector` keeps re-asking, the journal section that rots, and `promtool` in `make check` (cost it before writing anything). |
| `NEXT-PROMPT-session-exit-summary.md` | **pending** | Two volets: a per-command exit summary with four status markers, and the defect where a command prints "Safe to /clear" while an arbitration is still open. Implement them together; the exclusion rule between them is what makes either trustworthy. |
| `2026-08-01-session-handoff-2.md` | **current** | State of the repository, open chantiers (`test/action-pins-check.sh`, the GoReleaser 2.16.0 pin whose justification may have expired). |
| `NEXT-PROMPT-collector-outcome-seam.md` | **done** (PR #29) | Superseded by `docs/design/2026-08-01-collector-outcome-seam-design.md`, whose phase 2 is still open. Kept for the reasoning, not as a task. |
| `2026-08-01-resync-official-exporters-decoupage.md` | **done** (PRs #20, #22, #23) | The breakdown proposed for the official-exporter epic, and what verification changed about it before any of it was written. |
| `NEXT-PROMPT-resync-official-exporters.md` | **done** | The prompt that opened the epic. Its output is `docs/design/2026-08-01-official-exporter-gap-report.md`, which is where the remaining work lives: five adopted verdicts of ten are still unimplemented. |
| `2026-08-01-session-handoff.md` | **superseded** by handoff-2 | Kept because it records what the previous session learned, which handoff-2 summarises rather than repeats. |
| `2026-07-31-changelog-audit.md` | **done** | CHANGELOG audit that fed the v0.8.1 corrections. |
| `NEXT-PROMPT-docs-readme-refresh.md` | **done** (PRs #12, #15) | Predates this session's work. |
| `NEXT-PROMPT-v08-project-journal.md` | **done** (v0.8.0) | Predates this session's work. |

## Where the work that is still open actually lives

Not here. A prompt file is a starting instruction, not a backlog:

- **Five adopted verdicts of ten**, with their cost and their blast radius:
  `docs/design/2026-08-01-official-exporter-gap-report.md`.
- **Phase 2 of the collector seam**, removing the count-rule fallback:
  `docs/design/2026-08-01-collector-outcome-seam-design.md`.
- **Six plugin defects from field use**, each verified against the templates
  by grep rather than reported second-hand:
  `2026-08-03-friction-log-tapelibrary.md`.
- **Deliberate deviations, twenty-one of them**, so a later re-sync inherits
  the reasoning instead of re-litigating it: `docs/design/re-sync.md` §4.
