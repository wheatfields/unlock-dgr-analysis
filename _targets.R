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
  tar_target(ato_table1_raw,      download_ato_table1(paths$raw),      format = "file"),
  tar_target(ato_table3_raw,      download_ato_table3(paths$raw),      format = "file"),
  tar_target(ato_ancillary_raw,   download_ato_ancillary(paths$raw),   format = "file"),

  # ---- Per-source processing ------------------------------------------------
  # Each ingestion target reads the raw file, parses to a tidy table, and
  # writes a Parquet to data/processed/.

  tar_target(acnc_register, ingest_acnc_register(acnc_register_raw, paths$processed),
             format = "file"),

  # DGR status is looked up via the ABR API using the charity ABNs from the
  # register. Requires ABR_GUID env var — see R/ingest_abn_dgr.R for setup.
  tar_target(abn_dgr, ingest_abn_dgr(acnc_register, paths$processed),
             format = "file"),

  tar_target(acnc_ais,   ingest_acnc_ais(acnc_ais_raw,     paths$processed), format = "file"),
  tar_target(ato_table1,    ingest_ato_table1(ato_table1_raw,       paths$processed), format = "file"),
  tar_target(ato_table3,    ingest_ato_table3(ato_table3_raw,       paths$processed), format = "file"),
  tar_target(ato_ancillary, ingest_ato_ancillary(ato_ancillary_raw, paths$processed), format = "file"),

  # ---- Lookups --------------------------------------------------------------
  tar_target(target_subtype_mapping,
             file.path(paths$lookups, "target_subtype_mapping.csv"),
             format = "file"),

  # ---- Analytical layer -----------------------------------------------------
  # Joined, model-ready datasets written to data/analytical/ as both Parquet
  # and CSV. Parquet for DuckDB; CSV for Excel and other tools.

  tar_target(charity_master,
             build_charity_master(acnc_register, abn_dgr, target_subtype_mapping,
                                  paths$analytical),
             format = "file"),

  tar_target(charity_financials,
             build_charity_financials(charity_master, acnc_ais, paths$analytical),
             format = "file"),

  tar_target(gifts_timeseries,
             build_gifts_timeseries(ato_table1, paths$analytical),
             format = "file"),

  tar_target(gifts_by_income_year,
             build_gifts_by_income_year(ato_table3, paths$analytical),
             format = "file"),

  tar_target(ancillary_fund_stats,
             build_ancillary_fund_stats(ato_ancillary, paths$analytical),
             format = "file"),

  # ---- Build report ---------------------------------------------------------
  tar_target(build_summary,
             summarise_build(charity_master, charity_financials,
                             gifts_timeseries, gifts_by_income_year,
                             ancillary_fund_stats))
)
