#' Ingest the ACNC Annual Information Statement (AIS) financial data.
#'
#' Source: https://data.gov.au/data/dataset/acnc-2022-annual-information-statement-data
#' Format: CSV per AIS reporting year. Each row is a charity-year.
#' Update cadence: annual, with a long lag (most recent typically ~18 months
#'                 behind reporting year end).
#'
#' Currently scoped to AIS 2022 only. To add additional years:
#'   1. Find the dataset on data.gov.au (search "ACNC <year> AIS").
#'   2. Add a new entry to AIS_URLS below.
#'   3. download_acnc_ais() and ingest_acnc_ais() handle multiple years
#'      automatically; downstream code unions on common columns.
#'
#' VERIFY ON FIRST RUN:
#'   - Column harmonisation: ACNC has changed the AIS schema multiple times.
#'     A defensive ingestion checks each year independently and unions on a
#'     conservative set of common columns.
#'   - Currency / scale: dollar amounts are typically AUD nominal.
#'   - The ABN column may be named "ABN" (uppercase) or similar — janitor
#'     standardises to snake_case at ingestion.

AIS_URLS <- c(
  "2022" = "https://data.gov.au/data/dataset/311c24f3-fc09-42e7-8362-f15a76334a75/resource/cfbcf6f1-7ce5-472f-bfd3-a478e67e0366/download/datadotgov_ais22.csv"
)

download_acnc_ais <- function(raw_dir, force = FALSE) {
  dests <- vapply(names(AIS_URLS), function(yr) {
    dest <- raw_path(raw_dir, "acnc_ais",
                     sprintf("acnc_ais_%s_%s.csv", yr, today_stamp()))
    download_if_missing(AIS_URLS[[yr]], dest, force = force)
  }, character(1))
  unname(dests)
}

ingest_acnc_ais <- function(raw_files, processed_dir) {

  read_one <- function(path) {
    yr <- stringr::str_extract(basename(path), "(?<=ais_)\\d{4}")
    readr::read_csv(path, show_col_types = FALSE,
                    guess_max = 50000) |>
      janitor::clean_names() |>
      dplyr::mutate(ais_year = as.integer(yr))
  }

  # Read each year separately, then bind on common columns.
  per_year <- lapply(raw_files, read_one)

  common_cols <- Reduce(intersect, lapply(per_year, names))
  cli::cli_alert_info("AIS common columns across {length(per_year)} year(s): {length(common_cols)}")

  combined <- dplyr::bind_rows(
    lapply(per_year, dplyr::select, dplyr::all_of(common_cols))
  )

  # Standardise the ABN column. ACNC AIS files have used "ABN", "abn",
  # "AustralianBusinessNumber" historically; janitor::clean_names converts
  # any of these to lowercase forms we can detect.
  abn_candidates <- c("abn", "australian_business_number", "abn_number")
  abn_col <- intersect(abn_candidates, names(combined))[1]
  if (is.na(abn_col)) {
    cli::cli_abort(c(
      "Couldn't find an ABN column in AIS data.",
      "i" = "Columns present: {names(combined)}"
    ))
  }
  combined$abn <- stringr::str_remove_all(as.character(combined[[abn_col]]), "[^0-9]")

  out <- file.path(processed_dir, "acnc_ais.parquet")
  write_parquet_safely(combined, out)
}
