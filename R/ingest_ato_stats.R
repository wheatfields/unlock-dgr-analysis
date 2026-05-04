#' Ingest ATO Taxation Statistics — Individuals tables for charitable giving.
#'
#' Table 1A: time series of total gift amounts and donor counts, 1978-79 to 2022-23.
#' Table 3A: gifts by sex x taxable status x age range x taxable income range, 2022-23.
#'
#' File structure (verified against ts23individual01byyear.xlsx and
#' ts23individual03sextaxablestatusagerangetaxableincomerange.xlsx):
#'
#'   Table 1A: row 1 = title, row 2 = year column headers (1978-79 ... 2022-23),
#'             rows 3+ = items. "Gifts or donations" appears twice: once for
#'             donor count (unit = "no.") and once for total amount (unit = "$").
#'
#'   Table 3A: row 1 = title, row 2 = 169 column headers. Dimensions in cols 1-5
#'             (sex, taxable status, age range, income range, tax bracket). Gifts
#'             data in cols 67-68 ("Gifts or donations no." and "Gifts or
#'             donations $"). One row per demographic x income combination.
#'
#' Source: ATO Taxation Statistics 2022-23, data.gov.au.

ATO_TABLE1_URL <- "https://data.gov.au/data/dataset/03326c3f-c0d3-4af4-afc7-c6ccc0a02223/resource/f4a2a02f-92ca-49b4-bf4f-990e2226b687/download/ts23individual01byyear.xlsx"
ATO_TABLE3_URL <- "https://data.gov.au/data/dataset/03326c3f-c0d3-4af4-afc7-c6ccc0a02223/resource/a7f8226a-af03-431a-80f3-cdca85a9d63e/download/ts23individual03sextaxablestatusagerangerangetaxableincomerange.xlsx"

# ---- Downloads --------------------------------------------------------------

download_ato_table1 <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_individuals_table1_%s.xlsx", today_stamp()))
  download_if_missing(ATO_TABLE1_URL, dest, force = force)
}

download_ato_table3 <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_individuals_table3_%s.xlsx", today_stamp()))
  download_if_missing(ATO_TABLE3_URL, dest, force = force)
}

download_ato_stats <- function(raw_dir, force = FALSE) {
  c(download_ato_table1(raw_dir, force = force),
    download_ato_table3(raw_dir, force = force))
}

# ---- Ingestion --------------------------------------------------------------

#' Ingest ATO Individuals Table 1A (gifts time series).
#'
#' Outputs one row per income year with donor count and total gift amount.
ingest_ato_table1 <- function(raw_file, processed_dir) {
  # Read year labels from header row (row 2 of Excel, first row after skip = 1)
  hdr <- readxl::read_excel(raw_file, sheet = "Table 1A", skip = 1,
                             n_max = 1, col_names = FALSE)
  year_labels <- as.character(unlist(hdr[1, -(1:2)]))
  # Normalise Unicode dashes (en-dash U+2013, em-dash U+2014) to ASCII hyphen
  year_labels <- stringr::str_replace_all(year_labels, "[–—‒�]", "-")

  # Read data rows (skip title row + header row)
  raw <- readxl::read_excel(raw_file, sheet = "Table 1A", skip = 2, col_names = FALSE)
  names(raw) <- c("item", "unit", year_labels)

  gifts <- dplyr::filter(raw, stringr::str_detect(item, "(?i)gifts"))
  if (nrow(gifts) < 2) {
    cli::cli_abort("Expected 2 'Gifts or donations' rows in Table 1A, found {nrow(gifts)}")
  }

  count_row  <- suppressWarnings(as.integer(unlist(gifts[gifts$unit == "no.", -(1:2)])))
  amount_row <- suppressWarnings(as.numeric(unlist(gifts[gifts$unit == "$",   -(1:2)])))

  result <- data.frame(
    income_year          = year_labels,
    donors_no            = count_row,
    gifts_amount_dollars = amount_row,
    ingestion_date       = Sys.Date(),
    source_file          = basename(raw_file),
    stringsAsFactors     = FALSE
  )
  result <- dplyr::filter(result, !is.na(donors_no) | !is.na(gifts_amount_dollars))

  out <- file.path(processed_dir, "ato_individuals_table1.parquet")
  write_parquet_safely(result, out)
}

#' Ingest ATO Individuals Table 3A (gifts by demographic x income band).
#'
#' Outputs one row per sex x taxable status x age range x income range combination
#' with donor count and total gift amount for 2022-23.
ingest_ato_table3 <- function(raw_file, processed_dir) {
  raw <- readxl::read_excel(raw_file, sheet = "Table 3A", skip = 1, col_names = TRUE)

  # Identify gift columns by name before any cleaning (header has embedded newlines)
  gift_idx <- which(stringr::str_detect(names(raw), "(?i)gifts"))
  if (length(gift_idx) != 2) {
    cli::cli_abort(
      "Expected exactly 2 'Gifts or donations' columns in Table 3A, found {length(gift_idx)}"
    )
  }

  result <- raw[, c(1:5, gift_idx)]
  names(result) <- c("sex", "taxable_status", "age_range", "income_range", "tax_bracket",
                     "gifts_no", "gifts_amount_dollars")
  result <- dplyr::mutate(result,
    gifts_no             = suppressWarnings(as.integer(gifts_no)),
    gifts_amount_dollars = suppressWarnings(as.numeric(gifts_amount_dollars)),
    income_year          = "2022-23",
    ingestion_date       = Sys.Date(),
    source_file          = basename(raw_file)
  )
  result <- dplyr::filter(result, !is.na(gifts_no) | !is.na(gifts_amount_dollars))

  out <- file.path(processed_dir, "ato_individuals_table3.parquet")
  write_parquet_safely(result, out)
}

# Backward-compat wrapper kept so refresh_sources.R doesn't break.
ingest_ato_stats <- function(raw_file, processed_dir) {
  cli::cli_alert_warning("ingest_ato_stats() is deprecated; use table-specific functions.")
  ingest_ato_table1(raw_file, processed_dir)
}
