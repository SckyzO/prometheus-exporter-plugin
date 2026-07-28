# Running the golden matrix as a CI matrix

**Status:** design approved 2026-07-28. Small, self-contained change to this
repository's own CI. Touches no shipped template.

## 1. Goal

`golden-smoke` takes **24m43s** and every other job in `plugin-ci.yml`
finishes in under twenty seconds. The pipeline's latency is that one job,
and it is paid on every push, every pull request, and every Monday.

Measured on one cell locally, with warm caches, 84s total:

| Phase | Duration |
|---|---|
| `make check` (vet, lint, test, govulncheck, actionlint) | 33s |
| `make build` x3 and `docs-check` x3 (cell plus the two `/add-collector` sub-checks) | 37s |
| `docs-check` lie-injection round trip | 12s |
| scaffold plus eight static checks | 1s |
| `docker build` x2, syft, goreleaser, compose | 6s |

The container steps are 7% of a cell. The work is Go compilation and
`make check`, neither of which can be cut without weakening the gate. What
can be cut is the fact that six independent cells run one after another.

## 2. Why the loop is sequential today

`test/golden-smoke.sh:171-177` states the reason: every cell scaffolds under
the same `EXPORTER_NAME`, so the tools image tag
(`$(EXPORTER_NAME)-tools:latest`, `Makefile.tmpl:68`) is identical across
cells. Two cells building it at once would race on the tag and on its
`/tmp` stamp file. Running one cell to completion before starting the next
sidesteps that, and lets cells two through six reuse the first cell's image.

That reasoning is correct for one machine. It does not apply to six
runners: each has its own Docker daemon, its own `/tmp`, and its own
checkout, so there is no shared tag to race on. The constraint is a property
of the single-process driver, not of the cells.

## 3. Design

`golden-smoke` becomes a matrix of six jobs, one per cell, each invoking the
per-cell entry point the script already exposes
(`--flavor X --forge Y [--target-model Z]`).

```yaml
  golden-smoke:
    needs: scaffold-unit-tests
    runs-on: ubuntu-latest
    name: golden-smoke (${{ matrix.cell }})
    strategy:
      fail-fast: false
      matrix:
        include:
          - {cell: http-none,           args: --flavor http --forge none}
          - {cell: http-github,         args: --flavor http --forge github}
          - {cell: cli-none,            args: --flavor cli --forge none}
          - {cell: cli-github,          args: --flavor cli --forge github}
          - {cell: http-multi,          args: --flavor http --forge none --target-model multi}
          - {cell: http-multi-instance, args: --flavor http --forge none --target-model multi-instance}
    steps:
      - uses: actions/checkout@<pinned sha> # v7.0.1
        with:
          persist-credentials: false
      - run: sh test/golden-smoke.sh ${{ matrix.args }}
```

`fail-fast: false` preserves what `--all` does deliberately today: every
cell reports, so one broken cell does not hide the state of the other five.

The matrix is **static, not built from `fromJSON`**. A dynamically generated
matrix that comes back empty produces a job that succeeds without running
anything, which is a silent green. A literal list cannot be empty.

## 4. The drift guard

A static matrix duplicates the cell list that already lives in
`golden-smoke.sh`. Adding a seventh cell to the script would leave CI
running six, and nothing would say so. That is the failure mode this
repository refuses everywhere else, so it gets a guard rather than a
comment.

- `golden-smoke.sh` gains `--list-cells`, printing one cell name per line.
  The `for cell in ...` loop reads the same list, making the script the
  single source of truth.
- `scaffold-unit-tests`, which costs seven seconds, gains a step asserting
  that the workflow's matrix names exactly the cells the script lists, no
  more and no fewer.

The guard runs on the fast side of the pipeline, so a drift is reported in
seconds rather than after the matrix has finished.

## 5. Not doing

**Caching the tools image** (buildx `type=gha`, or building once and pushing
to GHCR). Each matrix job rebuilds it cold, which is redundant but parallel,
and the repository is public so the minutes are free. Both alternatives add
a cache-invalidation question and, for GHCR, a `packages: write` permission
and a public image to govern. Revisit only if the measured job time lands
above the estimate below.

**Removing `--all`.** It stays exactly as it is: it is the local entry
point, and it is what a contributor without six runners uses.

**Touching any shipped template.** The Makefile and Dockerfiles are
unchanged. This is a change to how this repository tests itself.

**Cutting any assertion.** The `/add-collector` sub-checks and the
`docs-check` lie-injection are 49s of the 84s, and they are what caught the
`config.example.yml` that never loaded and the `sed` that dragged appended
collectors into the wrong section.

## 6. Verification

- The first run on a pull request reports the real number. Expected six to
  nine minutes, gated by the slowest cell, against 24m43s today. This is an
  estimate: each job now repays the tools image cold, roughly three minutes,
  which the sequential run paid only once.
- Ten concurrent jobs at peak, against a limit of twenty for a public
  repository.
- The drift guard is proven by deleting a cell from the workflow and
  confirming `scaffold-unit-tests` goes red.
- `sh test/golden-smoke.sh --all` still passes locally and still reports all
  six cells.
