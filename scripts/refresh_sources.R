#' Force re-download of all source files.
#'
#'   source("scripts/refresh_sources.R")
#'
#' Run this when you want to pick up new ACNC/ABN/ATO releases. After this,
#' run scripts/build.R to rebuild downstream targets.

library(here)
lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

raw_dir <- "data/raw"

download_acnc_register(raw_dir, force = TRUE)
download_abn_dgr(raw_dir,       force = TRUE)
download_acnc_ais(raw_dir,      force = TRUE)
download_ato_stats(raw_dir,     force = TRUE)

# Invalidate downstream targets so the next build picks up the new files
if (requireNamespace("targets", quietly = TRUE)) {
  targets::tar_invalidate(dplyr::everything())
}

message("Sources refreshed. Run scripts/build.R to rebuild.")
