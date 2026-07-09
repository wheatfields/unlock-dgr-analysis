# Methodology

This document records every analytical decision and cross-references it to the code that implements it. When a number is challenged, the chain from raw data to headline figure should be traceable through this document.

## Project framing

**Goal.** Provide an analytical evidence base for Justice Connect's Unlock DGR campaign, validating or extending the Productivity Commission's modelling and characterising which charities benefit from DGR reform.

**Defensibility standard.** Findings should withstand Treasury-level scrutiny. Methodological choices are documented here with their rationale.

**Analytical approach.** Cross-sectional comparison of DGR-endorsed vs non-endorsed charities, stratified by the four campaign-target subtypes. A panel-based counterfactual is not feasible from public data because no clean before/after dataset tracking charities through DGR endorsement exists.

## Data sources

| Source | Pipeline file | Update cadence | Notes |
|---|---|---|---|
| ACNC Charity Register | `R/ingest_acnc_register.R` | Monthly | Primary classification |
| ABR API DGR lookups | `R/ingest_abn_dgr.R` | On demand | DGR endorsement status per ABN (no item numbers — see docs/abr_dgr_item_findings.md) |
| ACNC AIS financial data (2021–2024) | `R/ingest_acnc_ais.R` | Annual | Harmonised via `lookups/ais_column_mapping.csv` |
| ACNC AIS program classifications (CLASSIE) | `R/build_target_subtypes.R` | Annual | Drives target-cohort rules |
| ATO taxation statistics — gifts | `R/ingest_ato_stats.R` | Annual | Aggregate giving series |
| ATO taxation statistics — charities (Tables 3, 4A/4B) | `R/ingest_ato_charities.R` | Annual | DGR counts by type; PAF/PuAF time series (2023-24 edition) |

Most-recent versions used: see `data/raw/<source>/` filenames (date-stamped).

## Analytical layer

### `charity_master`
Built by `build_charity_master()` in `R/build_analytical.R`. One row per registered charity. Joins ACNC register to currently-endorsed DGR status from the ABR API, and adds the provisional ancillary-fund name flag. Campaign target cohorts live in `charity_target_subtypes` (single source of truth), not here.

**Key decisions:**

- *Definition of "currently endorsed":* an ABN has DGR status if the ABR lookup returned a non-missing `dgr_endorsed_from` date.
- *Ancillary flag:* `is_ancillary_provisional` is a case-insensitive name match on "ancillary" (294 charities). Undercounts funds whose names omit the word; ~580 register rows with ACNC-withheld ABNs are mostly private ancillary funds and cannot be flagged or joined.

### `charity_financials_panel`
Built by `build_charity_financials_panel()`. One row per charity × AIS year (2021–2024), harmonised through the explicit column mapping in `lookups/ais_column_mapping.csv` — ingestion errors loudly if a mapped column is missing from a vintage.

**Known limitations:**
- Reporting completeness varies by charity size — Basic Religious Charities and very small charities have lighter reporting requirements.
- Financials are self-reported and unaudited at the item level.

### `charity_target_subtypes`
Built by `build_charity_target_subtypes()` in `R/build_target_subtypes.R`. See "Target cohort definitions" below.

### Gifts and ancillary series
`gifts_timeseries`, `gifts_by_income_year` (ATO gift deduction statistics) and `ancillary_funds_timeseries`, `dgr_counts_by_type` (ATO charities tables, 2023-24 edition). Sector-level context and the Layer 1 pool; not per-charity analysis.

### Reform model outputs
`dgr_gap_analysis`, `reform_scenarios`, `dgr_incumbent_exposure` — see "Distributional analysis" below.

### Validation
Every build cross-checks 22 assertions against published anchors (ATO Taxation Statistics, ACNC AIS lodgment counts) and internal consistency rules — `validate_outputs()` in `R/validate_outputs.R`, target `validation_report`.

## The multiplier estimate

The Productivity Commission's $1.50-per-$1 figure is **cited, not re-derived**. A true counterfactual replication is not feasible from public data (no before/after dataset tracks charities through DGR endorsement). Instead, the donations-gap analysis (below) provides a cross-sectional plausibility check: whether the observed DGR vs non-DGR donation difference, within size × sector strata, is directionally consistent with the PC's modelling. Input dataset: `dgr_gap_analysis` (built by `build_dgr_gap_analysis()` in `R/build_reform_analysis.R`) — one row per charity × AIS year with harmonised financials, DGR status, target subtype, and strata variables. Charities flagged `is_ancillary_provisional` are excluded (grant-makers, not donation-seekers).

## Distributional analysis

Two-layer model of reform benefit, implemented in `R/build_reform_analysis.R`:

**Layer 1 — redistribution (`reform_scenarios`).** Annual PAF/PuAF distributions (2023-24: $1,527m, from `ancillary_funds_timeseries`) are legally restricted to DGRs. Recipient-level distribution data is never published by the ATO, so observed flows cannot be modelled; instead we estimate the share of the pool each target cohort could *access* under reform, using three mechanical allocation bases applied to the expanded eligible base (all charities with latest-year AIS financials): proportional to revenue (`revenue_share`), proportional to donations attracted (`donations_share`), and equal per charity (`count_share`). The bases are alternative assumptions, not an ordered low/high set; results are reported as the min–max range. Only non-DGR cohort members count as beneficiaries (leakage-adjusted — see cohort table below).

**Layer 2 — pie growth (owned separately).** DGR endorsement lowers the price of giving, so reform should also increase total donations. Estimated from the strata-matched donations gap in `dgr_gap_analysis`, cross-checked against the PC multiplier. Caveat applies: cross-sectional gaps reflect selection as well as any DGR effect.

**Losers (`dgr_incumbent_exposure`).** If flows partially redistribute rather than grow, incumbent DGR charities competing in the same donor markets bear the cost. For each cohort, incumbents are DGR charities sharing the cohort's ACNC purpose proxy, profiled by size band on donation dependence (donations / total gross income). For human_rights the purpose column *is* the cohort definition, so incumbents are the cohort's own DGR members. This is descriptive only — actual losses cannot be modelled from public data; under pure redistribution, cohort gains in `reform_scenarios` bound total incumbent losses.

### Target cohort definitions (frozen 2026-07-09)

Cohorts combine three auditable sources (see `build_charity_target_subtypes()`): the ACNC register human-rights purpose boolean, a manual ABN mapping (`data/mappings/target_subtypes.csv`), and 13 whitelisted rules in `lookups/target_subtype_rules.csv` (name keywords + CLASSIE program classifications). Key decisions:

- **"Prevention/preparedness includes response capability."** Disaster relief/recovery classifications count as disaster preparedness, and first-aid training counts as injury prevention. Applied consistently across both cohorts.
- Adjacent CLASSIE road-safety classes (motor vehicle / traffic safety) are both included — the split between them is a coding artefact, not a real distinction.
- Rules with `status = candidate` (e.g. search and rescue, fire brigades, public safety) are **not** applied; they remain in the candidate reports under `analysis/subtype_candidates/` for future review.

Cohort sizes and DGR leakage (distinct ABNs, register join, May 2026): disaster_preparedness 387 (66.7% already DGR), human_rights 851 (62.7%), injury_prevention 237 (67.1%), neighbourhood_house 312 (25.0%). These CLASSIE-based counts supersede the earlier purpose+name-keyword counts (259/86/79/847 in the stakeholder brief); the widening reflects program-level classification data unavailable to the original method. The earlier purpose+keyword system has been removed from the pipeline (its lookup remains in git history).

## Sensitivities and robustness

*[To be filled in.]*

## Known limitations

- Cross-sectional comparison cannot establish causation; observed differences between DGR and non-DGR charities reflect both DGR effects and unobserved selection.
- Manual subtype mapping is judgement-based and reviewed.
- AIS reporting lag means the most recent year of financial data is typically ~18 months stale.
