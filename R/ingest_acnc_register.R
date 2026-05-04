#' Ingest the ACNC Charity Register.
#'
#' Source: https://data.gov.au/data/dataset/acnc-register
#' Format: CSV (one row per registered charity).
#' Update cadence: monthly.
#'
#' VERIFY ON FIRST RUN:
#'   - Exact column names (ACNC sometimes renames between releases).
#'   - Whether DGR status is included on the register itself or only via the
#'     ABN Lookup file. Historically the register has a `Date Registered` and
#'     classification fields but DGR endorsement detail is in the ABN file.

# URL is configured here so it's swappable when ACNC publishes a new release.
ACNC_REGISTER_URL <- "https://data.gov.au/data/dataset/b050b242-4487-4306-abf5-07ca073e5594/resource/8fb32972-24e9-4c95-885e-7140be51be8a/download/datadotgov_main.csv"

download_acnc_register <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "acnc_register",
                   sprintf("acnc_register_%s.csv", today_stamp()))
  download_if_missing(ACNC_REGISTER_URL, dest, force = force)
}

ingest_acnc_register <- function(raw_file, processed_dir) {

  raw <- readr::read_csv(raw_file, show_col_types = FALSE) |>
    janitor::clean_names()

  # NOTE: Adjust column selection on first run after inspecting `names(raw)`.
  # Common columns include: abn, charity_name, charity_size, registration_status,
  # date_established, charity_subtype_*, main_activity, classification_*, town_city, state
  cleaned <- raw |>
    dplyr::mutate(
      abn = stringr::str_remove_all(as.character(abn), "[^0-9]"),
      ingestion_date = Sys.Date(),
      source_file = basename(raw_file)
    )

  out <- file.path(processed_dir, "acnc_register.parquet")
  write_parquet_safely(cleaned, out)
}
