#' Build analytical (joined, model-ready) datasets.
#'
#' Outputs land in data/analytical/ as Parquet. These are the files that get
#' synced to SharePoint for volunteers to query via DuckDB.

#' charity_master: one row per charity, with DGR status and target subtype flags.
build_charity_master <- function(register_path, dgr_path, mapping_path,
                                 analytical_dir) {

  register <- arrow::read_parquet(register_path)
  dgr      <- arrow::read_parquet(dgr_path)
  mapping  <- readr::read_csv(mapping_path, show_col_types = FALSE)

  # Currently-endorsed DGRs only (most recent endorsement per ABN)
  dgr_current <- dgr |>
    dplyr::filter(is_currently_endorsed) |>
    dplyr::group_by(abn) |>
    dplyr::summarise(
      has_dgr = TRUE,
      dgr_item_numbers = paste(unique(dgr_item_number), collapse = "|"),
      .groups = "drop"
    )

  master <- register |>
    dplyr::left_join(dgr_current, by = "abn") |>
    dplyr::mutate(has_dgr = !is.na(has_dgr) & has_dgr)

  # Apply target subtype mapping. The mapping file declares which ACNC
  # subtype/activity combinations correspond to each campaign target category
  # (neighbourhood houses, injury prevention, disaster preparedness, human
  # rights promotion). Joins are intentionally loose to support manual review.
  master <- attach_target_subtype(master, mapping)

  out <- file.path(analytical_dir, "charity_master.parquet")
  write_parquet_safely(master, out)
}

#' Loose-join helper: flag charities matching the manual subtype mapping.
attach_target_subtype <- function(master, mapping) {
  # The mapping has columns: acnc_subtype, activity_keyword, target_category, confidence.
  # Implementation of the join depends on which ACNC fields the team decides
  # to key off. Placeholder: a simple join on `charity_subtype` if present.
  if ("charity_subtype" %in% names(master) && "acnc_subtype" %in% names(mapping)) {
    master <- master |>
      dplyr::left_join(
        mapping |> dplyr::select(charity_subtype = acnc_subtype, target_category, confidence),
        by = "charity_subtype"
      )
  } else {
    master$target_category <- NA_character_
    master$confidence      <- NA_character_
  }
  master
}

#' charity_financials: one row per charity-year with key AIS items.
build_charity_financials <- function(charity_master_path, ais_path,
                                     analytical_dir) {

  master <- arrow::read_parquet(charity_master_path) |>
    dplyr::select(abn, has_dgr, target_category, charity_size,
                  dplyr::any_of(c("state", "main_activity")))
  ais <- arrow::read_parquet(ais_path)

  joined <- ais |>
    dplyr::inner_join(master, by = "abn")

  out <- file.path(analytical_dir, "charity_financials.parquet")
  write_parquet_safely(joined, out)
}

#' giving_aggregates: tidy the ATO/ACPNS aggregate giving series.
build_giving_aggregates <- function(ato_stats_path, analytical_dir) {

  ato <- arrow::read_parquet(ato_stats_path)

  # Pass-through for now; tidying logic added once the ATO sheet structure
  # is verified.
  out <- file.path(analytical_dir, "giving_aggregates.parquet")
  write_parquet_safely(ato, out)
}

#' Print a build summary so the operator knows what landed.
summarise_build <- function(charity_master_path, charity_financials_path,
                            giving_aggregates_path) {

  paths <- c(charity_master_path, charity_financials_path, giving_aggregates_path)
  for (p in paths) {
    df <- arrow::read_parquet(p, as_data_frame = FALSE)
    cli::cli_alert_info("{.path {p}}: {nrow(df)} rows, {ncol(df)} cols")
  }
  invisible(paths)
}
