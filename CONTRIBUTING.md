# Contributing — Adding a New Project

This repository is built to grow. Project 11, 12, 13… should be **mechanical to add**, because the structure,
naming, numbering, and diagram standards are already decided.

Do not invent a new layout. Copy the template.

---

## 1. Create the skeleton

```bash
cp -r templates/project-template project-11-<your-slug>
cd project-11-<your-slug>
```

Slug rules and full naming standards: [docs/CONVENTIONS.md](docs/CONVENTIONS.md#1-project-naming).

---

## 2. Design before you write YAML

Answer these **in writing** in `architecture/architecture.md` before creating a single manifest:

1. What application am I deploying, and why is it interesting? (Not "nginx".)
2. Which Kubernetes resources does this application **genuinely require**? Anything I can't justify gets cut.
3. What is the **failure** that motivates each resource? If I can't demonstrate the failure, the resource is being
   bolted on and the lesson won't land.
4. Which stages (`00`–`19`) apply? Which are legitimately skipped?
5. What does the coverage matrix gain from this project that isn't already 🟩 somewhere?

---

## 3. Build in phases

Follow the same 20-phase order Project 01 uses. Commit per phase — a reviewer should be able to read the git history
as a syllabus.

| Phase | Output |
|---|---|
| 1 | Application architecture + **HLD and LLD diagrams** |
| 2 | Application code (`application/`) |
| 3 | Dockerfiles + `scripts/build-images.sh` |
| 4–8 | `00-namespace` → `01-pods` → `02-replicasets` → `03-deployments` → `04-services` |
| 9–10 | `05-configmaps`, `06-secrets` |
| 11 | `07-storage`, `08-statefulsets` |
| 12 | `09-ingress`, `10-loadbalancer` |
| 13 | `11-health-checks` |
| 14 | `12-resources`, `13-hpa`, `14-pdb` |
| 15 | `15-security` |
| 16 | `16-jobs`, `17-observability` |
| 17 | `18-scheduling`, `failure-labs/` |
| 18 | `19-final` (combined manifest + kustomization) |
| 19 | `exercises/` + `exercises/solutions/`, `interview-questions/` |
| 20 | `scripts/cleanup.sh`, `scripts/manual-steps.md`, full clean-cluster run-through |

> `scripts/manual-steps.md` is written **as you build**, not afterwards — it's the record of the commands you actually
> ran. The scripts are then written to automate it, never the other way around.

---

## 4. Definition of Done

A project is **not** mergeable until every box is ticked.

### Structure
- [ ] Directory named `project-NN-<slug>`, number never reused
- [ ] All template directories present; unused stages **omitted, not renumbered**
- [ ] Every `manifests/NN-*/` has a `README.md` in the strict [WHY/WHAT/HOW format](docs/REPOSITORY-DESIGN.md#7-the-manifest-readme-format--why--what--how)

### Documentation
- [ ] Project `README.md` follows the 20-section standard template, in order
- [ ] **HLD diagram** present (colored, ≤15 nodes, in README § Application Architecture)
- [ ] **LLD diagram** present (colored, subgraphed, `Kind/name` labels, in README § Kubernetes Architecture)
- [ ] `architecture/architecture.mmd` contains the LLD source
- [ ] `architecture/request-flow.md` has a `sequenceDiagram` tracing one real request
- [ ] Diagram palette matches [CONVENTIONS.md §6](docs/CONVENTIONS.md#6-diagram-conventions) exactly — same colors mean the same layers in every project
- [ ] Every resource is introduced **problem-first**; no manifest appears before its motivating failure
- [ ] Theory is self-contained — zero "see Project XX for the explanation"
- [ ] `DEMO / LEARNING` vs `PRODUCTION CONSIDERATIONS` labelled wherever they differ
- [ ] No command without an explanation of what it does

### Navigation (a reader is never lost — see [CONVENTIONS.md §9](docs/CONVENTIONS.md#9-navigation-conventions--a-reader-is-never-lost))
- [ ] Every stage README opens with a **breadcrumb**: `⬅ Project` link, `Stage N of M`, and the full stage chain with the current one bold
- [ ] Every stage README closes with a **◀ Previous / ▲ Up / Next ▶** footer table
- [ ] Every stage README ends its body with **"The next problem"** — the failure that motivates the next stage, not "coming up next"
- [ ] Project README has the **journey diagram** (stage → failure → stage) and a **reading order table** with time estimates
- [ ] You can navigate the whole project start to finish **without ever using the browser back button**

### Official references ([CONVENTIONS.md §10](docs/CONVENTIONS.md#10-official-reference-conventions))
- [ ] Every stage README ends with a `## 📚 Official documentation` table (3–6 primary sources, placed before the nav footer)
- [ ] Every link **verified with curl to return 200** — never added from memory — and the block stamped with the verification date
- [ ] Primary sources only: `kubernetes.io/docs` or the tool's own site. No blogs, no Stack Overflow, no videos
- [ ] Any claim that contradicts common tutorial advice is cited inline
- [ ] References are additive — the lesson is complete without clicking anything

### Manifests
- [ ] `kubectl apply --dry-run=server -f` passes for every file
- [ ] Current stable API versions only; no deprecated groups
- [ ] Standard `app.kubernetes.io/*` labels on every object
- [ ] Selectors are minimal and stable (no `version` in `matchLabels`)
- [ ] No `:latest` tags anywhere
- [ ] `kubernetes.io/description` annotation on every object
- [ ] One logical resource per file, except in `19-final/`

### Runtime
- [ ] Deploys clean on a **freshly created** Kind cluster, from zero
- [ ] `scripts/deploy.sh`, `validate.sh`, `cleanup.sh` all work and are idempotent
- [ ] **`scripts/manual-steps.md` exists and covers every action the scripts perform** — raw commands, `What it does`
      / `Expected output` / `If it fails` for each, so the whole project can be completed without running any script
- [ ] The manual steps were actually followed end-to-end at least once (that's how you find the missing step)
- [ ] `validate.sh` exits non-zero when something is genuinely broken (test it by breaking something)
- [ ] `cleanup.sh` leaves **no** namespaces, PVs, PVCs, or cluster-scoped objects behind
- [ ] Project README states which `clusters/*.yaml` config it requires

### Learning content
- [ ] ≥ 6 failure labs, each with symptom → investigation commands → root cause → fix
- [ ] Beginner / intermediate / advanced exercises, with solutions in `exercises/solutions/`
- [ ] ≥ 15 interview questions grouped by resource, with model answers
- [ ] Production considerations section is specific, not generic advice

### Repository hygiene
- [ ] [docs/RESOURCE-COVERAGE-MATRIX.md](docs/RESOURCE-COVERAGE-MATRIX.md) updated **in the same commit**
- [ ] [docs/ROADMAP.md](docs/ROADMAP.md) and the root README project matrix updated
- [ ] No secrets, no real credentials, no cloud account IDs, no personal hostnames

---

## 5. Quality bar

| ❌ Reject | ✅ Accept |
|---|---|
| "Now create a Service." | "The frontend hardcodes `10.244.1.7`. We delete the pod, the IP changes, the page breaks. Kubernetes solves this with a Service." |
| A YAML file with no explanation | Field-by-field breakdown table |
| "Just run this command." | What the command does, what output to expect, what it means if the output differs |
| Deploying nginx as the subject | A real application with a real reason to need the resource |
| Cross-referencing another project for theory | Self-contained theory, duplicated on purpose |
| "Run `./deploy.sh`" as the only path | Scripts **plus** `manual-steps.md` with every raw command explained |
| Monochrome or default-themed diagrams | Colored diagrams using the fixed palette, HLD + LLD |
| Only happy-path content | Failure labs proving what breaks and how to find it |

---

## 6. Commit style

```
project-11: add <stage> — <what it teaches>

docs: <what changed>
fix(project-04): <what was wrong>
```

One phase per commit. The history should read like a syllabus, not a dump.
