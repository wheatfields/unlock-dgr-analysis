#' Ingest ATO Taxation Statistics — Charities Table 4 (ancillary funds).
#'
#' Table 4A: PAF and PuAF summary statistics, 2016-17 to 2022-23.
#' Table 4B: PAF and PuAF summary statistics, 2000-01 to 2015-16.
#'
#' These two sheets use the same row layout; combining them gives a full time
#' series from 2000-01.  Key metrics extracted:
#'   - total_funds_no        : cumulative count of approved funds
#'   - donations_received    : inflows to funds ($)
#'   - distributions_total   : total grants out of funds to DGR recipients ($)
#'   - net_assets            : fund assets at year end ($)
#'
#' Source: ATO Taxation Statistics 2022-23, data.gov.au dataset
#'   03326c3f-c0d3-4af4-afc7-c6ccc0a02223, resource
#'   10145889-8e82-4093-9620-fce2672fc34a.

ATO_ANCILLARY_URL <- "https://data.gov.au/data/dataset/03326c3f-c0d3-4af4-afc7-c6ccc0a02223/resource/10145889-8e82-4093-9620-fce2672fc34a/download/ts23charities04privatepublicancillaryfunds.xlsx"

# ---- Download ---------------------------------------------------------------

download_ato_ancillary <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_ancillary_funds_%s.xlsx", today_stamp()))
  download_if_missing(ATO_ANCILLARY_URL, dest, force = force)
}

# ---- Ingestion --------------------------------------------------------------

#' Parse one sheet (Table 4A or 4B) into a tidy long-format data frame.
#'
#' Row layout (0-indexed from top of sheet):
#'   Row 1 (skip)  : title
#'   Row 2 (skip)  : blank
#'   Row 3         : PAF section header ("Approved Private Ancillary Funds")
#'   Row 4         : "Total PAFs" count row       -> paf total_funds_no
#'   Row 5 (blank)
#'   Row 6         : "PAF donations received"     -> paf donations_received
#'   Row 7         : "PAF distributions made"     -> (header, skip)
#'   Rows 8-25     : distribution category rows   -> (skip, use row 25 total)
#'   Row 25        : "Total distributions made"   -> paf distributions_total
#'   Row 27        : "Net PAF assets"             -> paf net_assets
#'   Row 29        : PubAF section header         -> (skip)
#'   Row 30        : "Total PubAFs" count row     -> puaf total_funds_no
#'   Row 32        : "PubAF donations received"   -> puaf donations_received
#'   Row 33        : "PubAF distributions made"   -> (header, skip)
#'   Row 51        : "Total distributions made"   -> puaf distributions_total
#'   Row 53        : "Net PubAF assets"           -> puaf net_assets
#'
#' Year labels live in row 2 (col 3 onward).  Col 2 is the unit ("no." / "$").
parse_ancillary_sheet <- function(raw_file, sheet) {
  raw <- readxl::read_excel(raw_file, sheet = sheet, col_names = FALSE)

  # Year labels from row 2 (1-indexed), columns 3 onward
  year_row    <- as.character(unlist(raw[2, -(1:2)]))
  year_labels <- stringr::str_replace_all(year_row, "–|—|‒|�", "-")
  year_labels <- year_labels[!is.na(year_row)]
  n_years     <- length(year_labels)
  val_cols    <- seq(3, 2 + n_years)  # 1-indexed column positions

  extract_row <- function(row_idx) {
    as.numeric(unlist(raw[row_idx, val_cols]))
  }

  # Row indices (1-indexed) — verified against actual sheet layout
  paf_metrics  <- list(
    total_funds_no     = extract_row(4),
    donations_received = extract_row(6),
    distributions_total = extract_row(25),
    net_assets         = extract_row(27)
  )
  puaf_metrics <- list(
    total_funds_no      = extract_row(30),
    donations_received  = extract_row(32),
    distributions_total = extract_row(51),
    net_assets          = extract_row(53)
  )

  rows <- lapply(names(paf_metrics), function(m) {
    data.frame(
      fund_type   = rep(c("PAF", "PuAF"), each = n_years),
      metric      = m,
      income_year = rep(year_labels, 2),
      value       = c(paf_metrics[[m]], puaf_metrics[[m]]),
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows)
}

#' Ingest ATO ancillary fund statistics (Tables 4A + 4B combined).
#'
#' Outputs one row per fund_type x metric x income_year, covering 2000-01 to
#' 2022-23.  This supports the campaign argument that ~$11B (PAF) and ~$5B
#' (PuAF) in assets can only distribute to DGR charities, representing a direct
#' financial opportunity unlocked by DGR reform.
ingest_ato_ancillary <- function(raw_file, processed_dir) {
  sheet_4a <- parse_ancillary_sheet(raw_file, "Table 4A")
  sheet_4b <- parse_ancillary_sheet(raw_file, "Table 4B")

  combined <- rbind(sheet_4a, sheet_4b)
  combined <- dplyr::filter(combined, !is.na(value))
  combined <- dplyr::arrange(combined, fund_type, metric, income_year)
  combined$ingestion_date <- Sys.Date()
  combined$source_file    <- basename(raw_file)

  latest <- combined |>
    dplyr::filter(income_year == max(income_year[metric == "net_assets"]))

  for (ft in c("PAF", "PuAF")) {
    assets <- latest$value[latest$fund_type == ft & latest$metric == "net_assets"]
    if (length(assets) == 1) {
      cli::cli_alert_info(
        "{ft} net assets ({latest$income_year[latest$fund_type == ft & latest$metric == 'net_assets'][1]}): ${format(assets / 1e9, digits = 3)}B"
      )
    }
  }

  out <- file.path(processed_dir, "ato_ancillary_funds.parquet")
  write_parquet_safely(combined, out)
}
