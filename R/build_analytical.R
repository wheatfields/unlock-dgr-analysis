#' Build analytical (joined, model-ready) datasets.
#'
#' Outputs land in data/analytical/ as both Parquet and CSV. Parquet is for
#' volunteers querying via DuckDB; CSV is for Excel and other tools.

# ---- charity_master ---------------------------------------------------------

#' One row per charity with DGR status and a provisional ancillary-fund flag.
#' Target subtype flags live in charity_target_subtypes (the single source of
#' truth for campaign cohorts — see R/build_target_subtypes.R).
build_charity_master <- function(register_path, dgr_path, analytical_dir) {
  register <- arrow::read_parquet(register_path)
  dgr      <- arrow::read_parquet(dgr_path)

  # Derive has_dgr from dgr_endorsed_from rather than the has_dgr column in
  # abn_dgr.parquet. The ABR XML uses <dgrEndorsement>/<dgrFund> (camelCase)
  # but ingest_abn_dgr previously grepped for "DGR>|DGRFund>" (uppercase),
  # which never matched. dgr_endorsed_from is extracted from the inner
  # <endorsedFrom> tag and is correctly populated, so it's the reliable signal.
  dgr_current <- dgr |>
    dplyr::filter(!is.na(dgr_endorsed_from)) |>
    dplyr::mutate(has_dgr = TRUE) |>
    dplyr::select(abn, has_dgr, dgr_endorsed_from)

  master <- register |>
    dplyr::left_join(dgr_current, by = "abn") |>
    dplyr::mutate(has_dgr = !is.na(has_dgr) & has_dgr)

  # Provisional ancillary-fund flag. Neither the ABR bulk extract nor the ABR
  # API exposes DGR item numbers (see docs/abr_dgr_item_findings.md), so
  # Item 2 ancillary funds cannot be identified structurally. Name matching on
  # "ancillary" is the documented fallback; PAF naming guidelines mean most
  # (but not all) ancillary funds carry the phrase in their legal name.
  master <- master |>
    dplyr::mutate(
      is_ancillary_provisional = stringr::str_detect(
        charity_legal_name,
        stringr::regex("ancillary", ignore_case = TRUE)
      ) %in% TRUE
    )
  cli::cli_alert_info(
    "Provisional ancillary-fund flag: {sum(master$is_ancillary_provisional)} charities matched 'ancillary'"
  )

  out <- file.path(analytical_dir, "charity_master.parquet")
  write_outputs(master, out)
}

# ---- charity_financials_panel ------------------------------------------------

#' Long harmonised AIS financials panel (abn x ais_year), passed through to
#' the analytical layer. Column harmonisation is defined in
#' lookups/ais_column_mapping.csv and enforced at ingestion.
build_charity_financials_panel <- function(panel_path, analytical_dir) {
  raw <- arrow::read_parquet(panel_path)
  out <- file.path(analytical_dir, "charity_financials_panel.parquet")
  write_outputs(raw, out)
}

# ---- gifts tables -----------------------------------------------------------

#' National gifts time series (ATO Table 1A), passed through to analytical layer.
build_gifts_timeseries <- function(ato_table1_path, analytical_dir) {
  raw <- arrow::read_parquet(ato_table1_path)
  out <- file.path(analytical_dir, "gifts_timeseries.parquet")
  write_outputs(raw, out)
}

#' Gifts by demographic x income band (ATO Table 3A), passed through to analytical layer.
build_gifts_by_income_year <- function(ato_table3_path, analytical_dir) {
  raw <- arrow::read_parquet(ato_table3_path)
  out <- file.path(analytical_dir, "gifts_by_income_year.parquet")
  write_outputs(raw, out)
}

# ---- ATO charities tables (2023-24 edition) ---------------------------------

#' DGR endorsement counts by type (ATO charities Table 3), passed through to
#' analytical layer. One row per DGR category with the edition stamp.
build_dgr_counts_by_type <- function(ato_charities_table3_path, analytical_dir) {
  raw <- arrow::read_parquet(ato_charities_table3_path)
  out <- file.path(analytical_dir, "dgr_counts_by_type.parquet")
  write_outputs(raw, out)
}

#' Ancillary funds time series (ATO charities Tables 4A/4B), passed through to
#' analytical layer. One row per income_year x fund_type (PAF / PuAF).
build_ancillary_funds_timeseries <- function(ato_charities_table4_path,
                                             analytical_dir) {
  raw <- arrow::read_parquet(ato_charities_table4_path)
  out <- file.path(analytical_dir, "ancillary_funds_timeseries.parquet")
  write_outputs(raw, out)
}
