# Data dictionary

Schemas for the analytical outputs in `data/analytical/` (each written as Parquet + CSV, synced to the SharePoint `latest/` folder). Regenerate column lists after schema changes with `arrow::read_parquet(..., as_data_frame = FALSE) |> names()`.

Last updated: 2026-07-09 (10 outputs).

---

## `charity_master`

One row per ACNC-registered charity (65,430 rows). ACNC register fields joined to DGR status from the ABR API.

| Column | Type | Source | Description |
|---|---|---|---|
| `abn` | string | ACNC register | 11-digit ABN, digits only. NA for ~580 charities whose ABN is withheld (mostly private ancillary funds) |
| `charity_legal_name` | string | ACNC register | Registered legal name |
| `charity_size` | string | ACNC register | ACNC size classification (Small / Medium / Large) |
| `state`, `town_city`, `postcode`, ... | string | ACNC register | Registered address fields |
| `registration_date`, `financial_year_end`, ... | date/string | ACNC register | Registration attributes |
| `operates_in_*` | string (Y/blank) | ACNC register | State-of-operation flags |
| `pbi`, `hpc` | string (Y/blank) | ACNC register | Public benevolent institution / health promotion charity |
| *purpose booleans* (`advancing_health`, `promoting_or_protecting_human_rights`, ...) | string (Y/blank) | ACNC register | Declared charitable purposes |
| *beneficiary booleans* (`youth`, `females`, `victims_of_disasters`, ...) | string (Y/blank) | ACNC register | Declared beneficiary groups |
| `has_dgr` | bool | ABR API | TRUE if currently DGR-endorsed (derived from `dgr_endorsed_from`) |
| `dgr_endorsed_from` | string | ABR API | Date DGR endorsement took effect |
| `is_ancillary_provisional` | bool | Pipeline | Name-match flag on "ancillary" — provisional; see docs/abr_dgr_item_findings.md |
| `ingestion_date`, `source_file` | date/string | Pipeline | Provenance |

Note: DGR **item numbers** (Item 1 vs Item 2) are not available in any bulk ABR product — see docs/abr_dgr_item_findings.md. Campaign target cohorts are **not** in this table; use `charity_target_subtypes`.

---

## `charity_target_subtypes`

One row per charity × campaign subtype (1,860 rows; 1,745 distinct charities). The single source of truth for the four campaign cohorts.

| Column | Type | Source | Description |
|---|---|---|---|
| `abn` | string | ACNC register | 11-digit ABN (NA if withheld) |
| `charity_legal_name` | string | ACNC register | Legal name |
| `subtype` | string | Pipeline | neighbourhood_house / disaster_preparedness / injury_prevention / human_rights |
| `source` | string | Pipeline | register_boolean / manual_mapping / rule |
| `rule_id` | string | lookups/target_subtype_rules.csv | Which whitelisted rule matched (NA for register/manual) |
| `ingestion_date` | date | Pipeline | Provenance |

---

## `charity_financials_panel`

One row per charity × AIS year (211,895 rows; 2021–2024). Harmonised via `lookups/ais_column_mapping.csv`.

| Column | Type | Source | Description |
|---|---|---|---|
| `abn` | string | ACNC AIS | 11-digit ABN |
| `ais_year` | int | ACNC AIS | AIS reporting year (2021–2024) |
| `donations_and_bequests` | numeric | ACNC AIS | Donations and bequests received |
| `revenue_from_government` | numeric | ACNC AIS | Government grants/funding |
| `revenue_from_goods_and_services` | numeric | ACNC AIS | Fee-for-service revenue |
| `revenue_from_investments` | numeric | ACNC AIS | Investment revenue |
| `all_other_revenue`, `total_revenue`, `other_income`, `total_gross_income` | numeric | ACNC AIS | Other revenue aggregates |
| `grants_donations_in_australia`, `grants_donations_outside_australia` | numeric | ACNC AIS | Grants/donations the charity **made** |
| `total_expenses`, `total_assets`, `total_liabilities`, `net_assets` | numeric | ACNC AIS | Expenses and balance sheet |
| `ingestion_date` | date | Pipeline | Provenance |

---

## `dgr_gap_analysis`

Analysis-ready dataset for the DGR vs non-DGR donations-gap work (Layer 2). One row per charity × AIS year (198,141 rows). Panel financials joined to DGR status, size, state, purpose booleans, and target subtype. Provisional ancillary funds excluded.

Additional columns beyond the panel:

| Column | Type | Description |
|---|---|---|
| `charity_legal_name`, `charity_size`, `state` | string | From charity_master |
| `has_dgr`, `dgr_endorsed_from` | bool/string | DGR status |
| *4 purpose booleans* | string (Y/blank) | Strata variables (the SUBTYPE_PURPOSE_PROXY columns) |
| `target_subtype` | string | Semicolon-joined campaign subtypes (NA if none) |
| `donation_dependence` | numeric | donations_and_bequests / total_gross_income |

---

## `reform_scenarios`

Layer 1 scenario estimates: target-cohort access to the annual PAF/PuAF distribution pool (12 rows = 4 subtypes × 3 allocation bases). See docs/methodology.md ("Distributional analysis").

| Column | Type | Description |
|---|---|---|
| `subtype` | string | Campaign cohort |
| `n_cohort`, `n_newly_eligible` | int | Cohort members with latest-year financials; those without DGR |
| `pct_already_dgr` | numeric | Leakage: % of cohort already endorsed |
| `basis` | string | revenue_share / donations_share / count_share (alternative assumptions, not ordered) |
| `share_of_pool` | numeric | Cohort share of the expanded eligible base under that basis |
| `annual_dollars` | numeric | share_of_pool × pool_total |
| `pool_year`, `pool_total` | string/numeric | Latest income year and total PAF+PuAF distributions |

---

## `dgr_incumbent_exposure`

B2 losers analysis: incumbent DGR charities competing in each cohort's donor market, by size band (15 rows).

| Column | Type | Description |
|---|---|---|
| `subtype` | string | Campaign cohort whose market is profiled |
| `purpose_proxy` | string | ACNC purpose boolean used to define the donor market |
| `charity_size` | string | Size band |
| `n_incumbents` | int | DGR charities in the market (excl. cohort members, except human_rights — see methodology) |
| `total_donations` | numeric | Their combined donations (latest AIS year) |
| `median_donation_dependence` | numeric | Median donations / gross income |
| `n_highly_exposed` | int | Incumbents with donation dependence > 50% |

---

## `ancillary_funds_timeseries`

PAF/PuAF statistics by income year (37 rows; 2000-01 to 2023-24, ATO Taxation Statistics 2023-24 edition, Tables 4A/4B).

| Column | Type | Description |
|---|---|---|
| `income_year` | string | e.g. "2023-24" |
| `fund_type` | string | PAF / PuAF |
| `funds_approved`, `n_funds` | numeric | Newly approved and total operating funds |
| `donations_received` | numeric | Donations into funds ($) |
| `distributions_made` | numeric | Distributions to DGRs ($) |
| `net_assets` | numeric | Fund net assets ($) |
| `edition`, `ingestion_date`, `source_file` | string/date | Provenance |

---

## `dgr_counts_by_type`

DGR endorsement counts by category (31 rows; ATO charities Table 3, 2023-24 edition). Columns: `dgr_category`, `n`, `edition`, `ingestion_date`, `source_file`. Note: counts endorsements, not charities — an ABN can hold several.

---

## `gifts_timeseries`

National tax-deductible giving by individuals (41 rows; 1978-79 to 2022-23). Columns: `income_year`, `donors_no`, `gifts_amount_dollars`, `ingestion_date`, `source_file`.

---

## `gifts_by_income_year`

Gift deduction claims by donor demographic (1,322 rows; 2022-23). Columns: `sex`, `taxable_status`, `age_range`, `income_range`, `tax_bracket`, `gifts_no`, `gifts_amount_dollars`, `income_year`, `ingestion_date`, `source_file`.
