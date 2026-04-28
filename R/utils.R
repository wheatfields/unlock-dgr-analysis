#' Shared utilities for the ingestion pipeline.

#' Build a dated raw-file path.
#'
#' @param raw_dir Root raw directory (e.g. "data/raw").
#' @param source Subdirectory name (e.g. "acnc_register").
#' @param filename Filename within the source directory.
#' @return Absolute path; creates parent directories if needed.
raw_path <- function(raw_dir, source, filename) {
  dir <- file.path(raw_dir, source)
  if (!fs::dir_exists(dir)) fs::dir_create(dir, recurse = TRUE)
  file.path(dir, filename)
}

#' Today's date stamp for filenames.
today_stamp <- function() format(Sys.Date(), "%Y%m%d")

#' Write a tibble to Parquet, creating directories as needed.
write_parquet_safely <- function(df, path) {
  dir <- dirname(path)
  if (!fs::dir_exists(dir)) fs::dir_create(dir, recurse = TRUE)
  arrow::write_parquet(df, path)
  cli::cli_alert_success("Wrote {.path {path}} ({nrow(df)} rows, {ncol(df)} cols)")
  path
}

#' Download a URL to a local path, skipping if the file already exists.
#'
#' Set `force = TRUE` (or call refresh_sources.R) to re-download.
download_if_missing <- function(url, dest, force = FALSE) {
  if (fs::file_exists(dest) && !force) {
    cli::cli_alert_info("Using cached {.path {dest}}")
    return(dest)
  }
  cli::cli_alert("Downloading {.url {url}}")
  req <- httr2::request(url) |>
    httr2::req_user_agent("unlockdgr-pipeline/0.1 (hackathon)") |>
    httr2::req_timeout(120)
  resp <- httr2::req_perform(req, path = dest)
  cli::cli_alert_success("Saved to {.path {dest}}")
  dest
}

#' Quick validation: does a Parquet have at least N rows and the expected columns?
validate_parquet <- function(path, expected_cols, min_rows = 1) {
  df <- arrow::read_parquet(path, as_data_frame = FALSE)
  missing_cols <- setdiff(expected_cols, names(df))
  if (length(missing_cols) > 0) {
    cli::cli_abort("Missing expected columns in {.path {path}}: {missing_cols}")
  }
  if (nrow(df) < min_rows) {
    cli::cli_abort("{.path {path}} has only {nrow(df)} rows (expected >= {min_rows})")
  }
  invisible(TRUE)
}
