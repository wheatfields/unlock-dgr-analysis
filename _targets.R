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
    "stringr", "lubridate", "httr2", "fs", "cli", "here"
  ),
  format = "rds",
  error = "stop"
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
  # Each download target produces a dated raw file in data/raw/<source>/.
  # `cue = tar_cue(mode = "always")` would force re-download every run; we
  # default to manual refresh — see scripts/refresh_sources.R.

  tar_target(acnc_register_raw, download_acnc_register(paths$raw),
             format = "file"),
  tar_target(abn_dgr_raw,       download_abn_dgr(paths$raw),
             format = "file"),
  tar_target(acnc_ais_raw,      download_acnc_ais(paths$raw),
             format = "file"),
  tar_target(ato_stats_raw,     download_ato_stats(paths$raw),
             format = "file"),

  # ---- Per-source processing ------------------------------------------------
  # Each ingestion target reads the raw file, parses to a tidy table, and
  # writes a Parquet to data/processed/.

  tar_target(acnc_register, ingest_acnc_register(acnc_register_raw, paths$processed),
             format = "file"),
  tar_target(abn_dgr,       ingest_abn_dgr(abn_dgr_raw, paths$processed),
             format = "file"),
  tar_target(acnc_ais,      ingest_acnc_ais(acnc_ais_raw, paths$processed),
             format = "file"),
  tar_target(ato_stats,     ingest_ato_stats(ato_stats_raw, paths$processed),
             format = "file"),

  # ---- Lookups --------------------------------------------------------------
  tar_target(target_subtype_mapping,
             file.path(paths$lookups, "target_subtype_mapping.csv"),
             format = "file"),

  # ---- Analytical layer -----------------------------------------------------
  # Joined, model-ready datasets written to data/analytical/.
  # These are what volunteers query via DuckDB from SharePoint.

  tar_target(charity_master,
             build_charity_master(acnc_register, abn_dgr, target_subtype_mapping,
                                  paths$analytical),
             format = "file"),

  tar_target(charity_financials,
             build_charity_financials(charity_master, acnc_ais, paths$analytical),
             format = "file"),

  tar_target(giving_aggregates,
             build_giving_aggregates(ato_stats, paths$analytical),
             format = "file"),

  # ---- Build report ---------------------------------------------------------
  tar_target(build_summary, summarise_build(charity_master, charity_financials,
                                            giving_aggregates))
)
