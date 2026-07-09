#' targets pipeline for Unlock DGR analysis.
#'
#' Run with `targets::tar_make()` or `source("scripts/build.R")`.
#' Inspect with `targets::tar_visnetwork()`.

library(targets)
library(tarchetypes)

# Source all functions in R/
lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

# Pipeline-wide options
tar_option_set(
  packages = c(
    "arrow", "duckdb", "dplyr", "readr", "janitor",
    "stringr", "lubridate", "httr2", "fs", "cli", "here", "readxl"
  ),
  format = "rds",
  error  = "stop"
)

# Paths (relative to project root)
paths <- list(
  raw        = "data/raw",
  processed  = "data/processed",
  analytical = "data/analytical",
  lookups    = "lookups"
)

list(
  # ---- Source downloads -----------------------------------------------------
  # Each download target produces a dated raw file under data/raw/<source>/.
  # Re-running tar_make() does NOT re-download; use scripts/refresh_sources.R
  # to force a re-fetch.

  tar_target(acnc_register_raw, download_acnc_register(paths$raw), format = "file"),
  tar_target(acnc_ais_raw,      download_acnc_ais(paths$raw),      format = "file"),
  tar_target(acnc_ais_programs_raw, download_acnc_ais_programs(paths$raw),
             format = "file"),
  tar_target(ato_table1_raw,      download_ato_table1(paths$raw),      format = "file"),
  tar_target(ato_table3_raw,      download_ato_table3(paths$raw),      format = "file"),
  tar_target(ato_charities_table3_raw, download_ato_charities_table3(paths$raw),
             format = "file"),
  tar_target(ato_charities_table4_raw, download_ato_charities_table4(paths$raw),
             format = "file"),

  # ---- Per-source processing ------------------------------------------------
  # Each ingestion target reads the raw file, parses to a tidy table, and
  # writes a Parquet to data/processed/.

  tar_target(acnc_register, ingest_acnc_register(acnc_register_raw, paths$processed),
             format = "file"),

  # DGR status is looked up via the ABR API using the charity ABNs from the
  # register. Requires ABR_GUID env var — see R/ingest_abn_dgr.R for setup.
  tar_target(abn_dgr, ingest_abn_dgr(acnc_register, paths$processed),
             format = "file"),

  # Harmonised multi-vintage AIS financials. Column selection is fully
  # specified in lookups/ais_column_mapping.csv (one row per vintage-column);
  # ingest aborts if a mapped column is missing from a vintage.
  tar_target(ais_column_mapping,
             file.path(paths$lookups, "ais_column_mapping.csv"),
             format = "file"),
  tar_target(ais_financials_panel_processed,
             ingest_ais_financials_panel(acnc_ais_raw, ais_column_mapping,
                                         paths$processed),
             format = "file"),

  tar_target(ato_table1,    ingest_ato_table1(ato_table1_raw,       paths$processed), format = "file"),
  tar_target(ato_table3,    ingest_ato_table3(ato_table3_raw,       paths$processed), format = "file"),
  tar_target(ato_charities_table3,
             ingest_ato_charities_table3(ato_charities_table3_raw, paths$processed),
             format = "file"),
  tar_target(ato_charities_table4,
             ingest_ato_charities_table4(ato_charities_table4_raw, paths$processed),
             format = "file"),

  # ---- Lookups --------------------------------------------------------------
  # Target subtype scaffolding: curated ABN list + auditable rules file.
  # Only rules with status == "whitelisted" reach charity_target_subtypes;
  # everything else only feeds the candidate CSVs for human review.
  tar_target(target_subtypes_manual,
             "data/mappings/target_subtypes.csv",
             format = "file"),
  tar_target(target_subtype_rules,
             file.path(paths$lookups, "target_subtype_rules.csv"),
             format = "file"),

  # ---- Analytical layer -----------------------------------------------------
  # Joined, model-ready datasets written to data/analytical/ as both Parquet
  # and CSV. Parquet for DuckDB; CSV for Excel and other tools.

  tar_target(charity_master,
             build_charity_master(acnc_register, abn_dgr, paths$analytical),
             format = "file"),

  tar_target(charity_financials_panel,
             build_charity_financials_panel(ais_financials_panel_processed,
                                            paths$analytical),
             format = "file"),

  tar_target(gifts_timeseries,
             build_gifts_timeseries(ato_table1, paths$analytical),
             format = "file"),

  tar_target(gifts_by_income_year,
             build_gifts_by_income_year(ato_table3, paths$analytical),
             format = "file"),

  tar_target(dgr_counts_by_type,
             build_dgr_counts_by_type(ato_charities_table3, paths$analytical),
             format = "file"),

  tar_target(ancillary_funds_timeseries,
             build_ancillary_funds_timeseries(ato_charities_table4, paths$analytical),
             format = "file"),

  # Diagnostic candidate CSVs for subtype review (analysis/subtype_candidates/).
  tar_target(subtype_candidates,
             report_subtype_candidates(acnc_ais_programs_raw, acnc_register,
                                       target_subtype_rules),
             format = "file"),

  tar_target(charity_target_subtypes,
             build_charity_target_subtypes(acnc_register, acnc_ais_programs_raw,
                                           target_subtypes_manual,
                                           target_subtype_rules,
                                           paths$analytical),
             format = "file"),

  # ---- Reform analysis (two-layer model) ------------------------------------
  # Layer 2 handoff dataset: charity-year financials + DGR status + subtype +
  # strata variables, ancillary funds excluded. Input for the donations-gap
  # analysis owned by another team member.
  tar_target(dgr_gap_analysis,
             build_dgr_gap_analysis(charity_master, charity_financials_panel,
                                    charity_target_subtypes, paths$analytical),
             format = "file"),

  # Layer 1: scenario ranges for target-cohort access to the annual PAF/PuAF
  # distribution pool (leakage-adjusted; access scenarios, not predicted flows).
  tar_target(reform_scenarios,
             build_reform_scenarios(dgr_gap_analysis,
                                    ancillary_funds_timeseries,
                                    paths$analytical),
             format = "file"),

  # B2: descriptive exposure of incumbent DGR charities competing in the same
  # donor markets as the target cohorts.
  tar_target(dgr_incumbent_exposure,
             build_incumbent_exposure(dgr_gap_analysis, paths$analytical),
             format = "file"),

  # ---- Validation -----------------------------------------------------------
  # Cross-checks outputs against published anchors (ATO ts24, ACNC AIS counts)
  # and internal consistency rules. Returns a tibble of PASS/FAIL checks.
  tar_target(validation_report,
             validate_outputs(charity_master, dgr_counts_by_type,
                              ancillary_funds_timeseries,
                              charity_financials_panel,
                              dgr_gap_analysis, reform_scenarios,
                              dgr_incumbent_exposure))
)
