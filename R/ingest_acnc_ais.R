#' Ingest the ACNC Annual Information Statement (AIS) financial data.
#'
#' Source: https://data.gov.au/data/dataset/acnc-annual-information-statement
#'         (separate datasets per reporting year)
#' Format: CSV per AIS reporting year. Each row is a charity-year.
#' Update cadence: annual, with a long lag (most recent typically ~18 months
#'                 behind reporting year end).
#'
#' VERIFY ON FIRST RUN:
#'   - Available reporting years (set AIS_YEARS below).
#'   - Column harmonisation: ACNC has changed the AIS schema multiple times.
#'     A defensive ingestion checks each year independently and unions on a
#'     conservative set of common columns.
#'   - Currency / scale: dollar amounts are typically AUD nominal.

# Update this vector when new AIS years are released.
AIS_YEARS <- c(2018, 2019, 2020, 2021, 2022, 2023)

# URL pattern — replace with actual data.gov.au resource URLs per year.
AIS_URLS <- setNames(
  sprintf("https://data.gov.au/data/dataset/PLACEHOLDER/ais-%d.csv", AIS_YEARS),
  AIS_YEARS
)

download_acnc_ais <- function(raw_dir, force = FALSE) {
  dests <- vapply(names(AIS_URLS), function(yr) {
    dest <- raw_path(raw_dir, "acnc_ais",
                     sprintf("acnc_ais_%s_%s.csv", yr, today_stamp()))
    download_if_missing(AIS_URLS[[yr]], dest, force = force)
  }, character(1))
  dests
}

ingest_acnc_ais <- function(raw_files, processed_dir) {

  read_one <- function(path) {
    yr <- stringr::str_extract(basename(path), "(?<=ais_)\\d{4}")
    readr::read_csv(path, show_col_types = FALSE) |>
      janitor::clean_names() |>
      dplyr::mutate(
        ais_year = as.integer(yr),
        abn = stringr::str_remove_all(as.character(abn), "[^0-9]")
      )
  }

  # Read each year separately, then bind on common columns.
  per_year <- lapply(raw_files, read_one)

  common_cols <- Reduce(intersect, lapply(per_year, names))
  cli::cli_alert_info("AIS common columns across years: {length(common_cols)}")

  combined <- dplyr::bind_rows(lapply(per_year, dplyr::select, dplyr::all_of(common_cols)))

  out <- file.path(processed_dir, "acnc_ais.parquet")
  write_parquet_safely(combined, out)
}
