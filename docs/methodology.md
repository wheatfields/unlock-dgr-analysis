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
| ABN Lookup DGR list | `R/ingest_abn_dgr.R` | Weekly | DGR endorsement detail |
| ACNC AIS financial data | `R/ingest_acnc_ais.R` | Annual | Charity-level financials by year |
| ATO taxation statistics | `R/ingest_ato_stats.R` | Annual | Aggregate giving series |

Most-recent versions used: see `data/raw/<source>/` filenames (date-stamped).

## Analytical layer

### `charity_master`
Built by `build_charity_master()` in `R/build_analytical.R`. One row per registered charity. Joins ACNC register to currently-endorsed DGR status from the ABN file. Attaches a target-subtype flag using the manual mapping in `lookups/target_subtype_mapping.csv`.

**Key decisions** (to be filled in as the team makes them):

- *Definition of "currently endorsed":* an ABN is treated as having DGR status if it has at least one DGR endorsement record with `endorsement_to` either null or in the future.
- *Subtype mapping confidence:* see the `confidence` column in the lookup. High-confidence matches are used in headline figures; medium-confidence matches are reported separately as a sensitivity.

### `charity_financials`
Built by `build_charity_financials()`. One row per charity-year. AIS items joined to charity attributes from `charity_master`.

**Known limitations:**
- Schema changes across AIS years; only common columns are retained.
- Reporting completeness varies by charity size — Basic Religious Charities and very small charities have lighter reporting requirements.

### `giving_aggregates`
Built by `build_giving_aggregates()`. ATO/ACPNS aggregate giving series. Used for sector-level context, not per-charity analysis.

## The multiplier estimate

*[To be filled in once the team scopes the replication/extension of the PC's $1.50 figure.]*

## Distributional analysis

*[To be filled in once the team scopes which charity cohorts are likely to benefit / lose out from reform.]*

## Sensitivities and robustness

*[To be filled in.]*

## Known limitations

- Cross-sectional comparison cannot establish causation; observed differences between DGR and non-DGR charities reflect both DGR effects and unobserved selection.
- Manual subtype mapping is judgement-based and reviewed.
- AIS reporting lag means the most recent year of financial data is typically ~18 months stale.
