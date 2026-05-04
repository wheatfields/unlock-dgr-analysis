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
#'
#' Uses a browser-like User-Agent because some data.gov.au resources return
#' a 404 page when the request looks programmatic. Also sniffs the response
#' body for HTML markers — some servers report a non-HTML Content-Type but
#' return HTML anyway (looking at you, abr.business.gov.au).
download_if_missing <- function(url, dest, force = FALSE) {
  if (fs::file_exists(dest) && !force) {
    cli::cli_alert_info("Using cached {.path {dest}}")
    return(dest)
  }
  cli::cli_alert("Downloading {.url {url}}")
  req <- httr2::request(url) |>
    httr2::req_user_agent(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ) |>
    httr2::req_headers(
      Accept = "*/*",
      `Accept-Language` = "en-AU,en;q=0.9"
    ) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3)
  resp <- httr2::req_perform(req, path = dest)

  # Two checks: Content-Type header AND first bytes of the body.
  # ABR misreports content type, so we can't trust the header alone.
  # But for known-binary file types, sniffing the body as text is itself
  # unsafe (raw bytes can be invalid UTF-8 sequences and crash rawToChar),
  # so we skip the body sniff for those.
  ctype <- httr2::resp_content_type(resp)
  binary_ext <- grepl("\\.(zip|xlsx|xls|gz|tar|7z|pdf|parquet)$", dest,
                      ignore.case = TRUE)
  looks_like_html <- FALSE
  if (!binary_ext) {
    con <- file(dest, "rb")
    first_bytes <- readBin(con, "raw", n = 200)
    close(con)
    body_text <- iconv(rawToChar(first_bytes[first_bytes != as.raw(0)]),
                       to = "UTF-8", sub = "")
    body_start <- tolower(body_text)
    looks_like_html <- grepl("<!doctype|<html|<head", body_start)
  }

  if (grepl("html", ctype, ignore.case = TRUE) || looks_like_html) {
    fs::file_delete(dest)
    cli::cli_abort(c(
      "Server returned HTML rather than data.",
      "i" = "URL: {url}",
      "i" = "Content-Type was: {ctype}",
      "i" = "Open the URL in a browser to confirm it serves a real file."
    ))
  }
  cli::cli_alert_success("Saved to {.path {dest}}")
  dest
}

#' Write a data frame to both Parquet and CSV. Returns the Parquet path.
#'
#' Used for analytical outputs (data/analytical/) so volunteers can use either
#' format. Processed intermediates use write_parquet_safely() only.
write_outputs <- function(df, parquet_path) {
  write_parquet_safely(df, parquet_path)
  csv_path <- sub("\\.parquet$", ".csv", parquet_path)
  readr::write_csv(df, csv_path)
  cli::cli_alert_success("Wrote CSV:     {.path {csv_path}}")
  invisible(parquet_path)
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
