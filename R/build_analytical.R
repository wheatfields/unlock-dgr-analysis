#' Build analytical (joined, model-ready) datasets.
#'
#' Outputs land in data/analytical/ as both Parquet and CSV. Parquet is for
#' volunteers querying via DuckDB; CSV is for Excel and other tools.

# ---- charity_master ---------------------------------------------------------

#' One row per charity with DGR status and target category flags.
build_charity_master <- function(register_path, dgr_path, mapping_path,
                                 analytical_dir) {
  register <- arrow::read_parquet(register_path)
  dgr      <- arrow::read_parquet(dgr_path)
  mapping  <- readr::read_csv(mapping_path, show_col_types = FALSE)

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

  master <- attach_target_subtype(master, mapping)

  out <- file.path(analytical_dir, "charity_master.parquet")
  write_outputs(master, out)
}

#' Flag charities matching the campaign's four target categories.
#'
#' Matching strategy:
#'   1. The relevant ACNC boolean purpose column must equal "Y".
#'   2. The charity's legal name must contain the activity keyword (case-insensitive).
#'
#' The ACNC register has boolean purpose columns but no free-text activity field,
#' so name-based keyword matching is the best available proxy. Rows in the
#' mapping CSV are processed in order; the first match wins (higher-confidence
#' rows should appear first).
attach_target_subtype <- function(master, mapping) {
  # Maps human-readable acnc_subtype labels in the CSV to the actual column
  # names produced by janitor::clean_names() on the ACNC register.
  purpose_col_map <- c(
    "advancing social or public welfare" =
      "advancing_social_or_public_welfare",
    "advancing health" =
      "advancing_health",
    "advancing the security or safety of australia or the australian public" =
      "advancing_security_or_safety_of_australia_or_australian_public",
    "promoting or protecting human rights" =
      "promoting_or_protecting_human_rights"
  )

  master$target_category <- NA_character_
  master$confidence      <- NA_character_

  for (i in seq_len(nrow(mapping))) {
    purpose_col <- purpose_col_map[tolower(trimws(mapping$acnc_subtype[i]))]
    if (is.na(purpose_col) || !purpose_col %in% names(master)) next

    purpose_match <- !is.na(master[[purpose_col]]) & master[[purpose_col]] == "Y"
    keyword_match <- stringr::str_detect(
      master$charity_legal_name,
      stringr::regex(mapping$activity_keyword[i], ignore_case = TRUE)
    )
    untagged <- is.na(master$target_category)

    hits <- purpose_match & keyword_match & untagged
    master$target_category[hits] <- mapping$target_category[i]
    master$confidence[hits]      <- mapping$confidence[i]
  }

  n_tagged <- sum(!is.na(master$target_category))
  cli::cli_alert_info("Target subtype mapping: {n_tagged} charities tagged")
  master
}

# ---- charity_financials -----------------------------------------------------

#' One row per charity-year with AIS financial items joined to master attributes.
build_charity_financials <- function(charity_master_path, ais_path,
                                     analytical_dir) {
  master <- arrow::read_parquet(charity_master_path) |>
    dplyr::select(abn, has_dgr, target_category, charity_size,
                  dplyr::any_of(c("state", "main_activity")))
  ais <- arrow::read_parquet(ais_path)

  joined <- dplyr::inner_join(ais, master, by = "abn")

  out <- file.path(analytical_dir, "charity_financials.parquet")
  write_outputs(joined, out)
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

# ---- build summary ----------------------------------------------------------

summarise_build <- function(...) {
  paths         <- c(...)
  parquet_paths <- paths[grepl("\\.parquet$", paths)]
  for (p in parquet_paths) {
    df <- arrow::read_parquet(p, as_data_frame = FALSE)
    cli::cli_alert_info("{.path {p}}: {nrow(df)} rows, {ncol(df)} cols")
  }
  invisible(paths)
}
