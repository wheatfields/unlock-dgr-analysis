# Unlock DGR Analysis

Analytical evidence base for Justice Connect's Unlock DGR campaign, built during the 2026 Actuaries Institute Hackathon.

## What this repo contains

- **Ingestion code** that downloads public data (ACNC Charity Register, ABR DGR lookups, ACNC AIS financials 2021–2024, ATO taxation statistics), cleans it, and writes versioned Parquet outputs.
- **A reproducible pipeline** (`targets`) so the entire build runs end-to-end with one command.
- **Lookup tables** including the auditable rules file and manual mapping that define the four campaign-target cohorts.
- **Reform model outputs** — two-layer DGR reform benefit model (pool-access scenarios, donations-gap handoff dataset, incumbent exposure).
- **Methodology documentation** cross-referenced to the code that implements it.

## What this repo does NOT contain

- Volunteer exploratory analysis. That happens in a shared workspace (SharePoint), against the Parquet outputs this pipeline produces. Finalised analysis files are handed to the repo owner and committed under `analysis/`.
- Raw downloaded files. These live locally in `data/raw/` (gitignored) for size and reproducibility reasons. The ingestion scripts re-fetch them from source.

## Who does what

| Role | Action |
|---|---|
| Repo owner (you) | Owns commits to this repo. Runs the pipeline. Syncs Parquet outputs to SharePoint. Reviews and commits finalised analysis files. |
| Volunteers | Connect to Parquet outputs in SharePoint via DuckDB. Do exploratory analysis in their own notebooks/scripts. Hand finished work to the repo owner. |

## Quick start (repo owner)

```r
# One-time setup
source("scripts/setup.R")

# Run the full pipeline
source("scripts/build.R")

# Sync analytical outputs to SharePoint
source("scripts/sync_outputs.R")
```

## Quick start (volunteers)

See [`docs/volunteer_setup.md`](docs/volunteer_setup.md). Volunteers do not clone this repo.

## Project structure

```
unlock-dgr-analysis/
├── _targets.R              # Pipeline definition
├── DESCRIPTION             # R package dependencies
├── R/                      # Functions called by the pipeline
│   ├── ingest_*.R          # One file per data source
│   ├── build_analytical.R  # Joins and derived tables
│   └── utils.R
├── data/
│   ├── raw/                # Source downloads (gitignored, dated)
│   ├── processed/          # Cleaned per-source Parquet
│   └── analytical/         # Joined, model-ready Parquet (synced to SharePoint)
├── lookups/                # Manual mappings (versioned in Git)
├── analysis/               # Finalised volunteer analyses
├── docs/                   # Methodology, data dictionary, setup
└── scripts/                # Entry points: setup, build, sync
```

## Defensibility

Every analytical figure should be traceable from raw source download → ingestion script → processed Parquet → analytical Parquet → analysis file. The methodology doc (`docs/methodology.md`) cross-references each transformation step to the function that implements it. When a number is challenged, the chain is in code, not in inboxes.
