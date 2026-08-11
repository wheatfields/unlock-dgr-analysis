# Summary graph for the DGR endorsement event study.
# Reads the CSV outputs produced by dgr_endorsement_event_study.R.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
})

out_dir <- file.path(here::here(), "analysis", "dgr_event_study")

levels <- read.csv(file.path(out_dir, "levels_real_by_event_year.csv"))
shares <- read.csv(file.path(out_dir, "event_time_summary.csv")) |>
  filter(!is_startup)
dep    <- read.csv(file.path(out_dir, "baseline_dependence_split.csv"))
three  <- read.csv(file.path(out_dir, "three_cohort_by_year.csv"))
growth <- read.csv(file.path(out_dir, "three_cohort_growth.csv"))

cohort_labels <- c(switcher = "Switchers (endorsed 2020-23)",
                   always   = "Always DGR (pre-2019)",
                   never    = "Never DGR")
cohort_cols <- c("Switchers (endorsed 2020-23)" = "#D55E00",
                 "Always DGR (pre-2019)"        = "#7f7f7f",
                 "Never DGR"                    = "#b0b0b0")

# Panel A (hero): three cohorts, median real donations indexed to 2019 = 100.
pa_dat <- three |>
  group_by(cohort3) |>
  mutate(index = 100 * med_donations_real / med_donations_real[ais_year == 2019]) |>
  ungroup() |>
  mutate(cohort = factor(cohort_labels[cohort3], unname(cohort_labels)))

pa <- ggplot(pa_dat, aes(ais_year, index, colour = cohort)) +
  geom_hline(yintercept = 100, linetype = "dotted", colour = "grey60") +
  geom_line(aes(linewidth = cohort == cohort_labels["switcher"])) +
  geom_point(size = 2.2) +
  scale_linewidth_manual(values = c(`TRUE` = 1.4, `FALSE` = 0.7), guide = "none") +
  scale_colour_manual(values = cohort_cols) +
  labs(title = "A. Median real donations by cohort (2019 = 100)",
       subtitle = paste0(
         "Switchers pool four cohorts endorsed 2020-23; each steps up once at its own\n",
         "endorsement year, so the staggered jumps render as a ramp"),
       x = "AIS year", y = "Index (2019 = 100)", colour = NULL) +
  theme_minimal() + theme(legend.position = "bottom") +
  guides(colour = guide_legend(nrow = 3))

# Panel D: within-charity real donation growth 2019->2024 (balanced) — the
# cleanest "switchers are different" statistic.
pd_dat <- growth |>
  mutate(cohort = factor(cohort_labels[cohort3], unname(cohort_labels)))

pd <- ggplot(pd_dat, aes(cohort, med_real_growth, fill = cohort)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = scales::percent(med_real_growth, accuracy = 1)),
            vjust = -0.4, size = 4) +
  scale_fill_manual(values = cohort_cols, guide = "none") +
  scale_y_continuous(labels = scales::percent,
                     expand = expansion(mult = c(0.02, 0.15))) +
  labs(title = "D. Within-charity real donation growth, 2019 to 2024",
       subtitle = "Same charities observed in both years; median growth",
       x = NULL, y = "Median real growth") +
  theme_minimal() +
  theme(axis.text.x = element_text(size = 8))

# Panel B: donation share by event year (mean vs median) — the "flat" headline
pb <- shares |>
  pivot_longer(c(mean_share, median_share), names_to = "stat",
               values_to = "share") |>
  mutate(stat = if_else(stat == "mean_share", "Mean", "Median")) |>
  ggplot(aes(event_year, share, colour = stat)) +
  geom_line(linewidth = 1) + geom_point(size = 2) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey40") +
  scale_y_continuous(labels = scales::percent, limits = c(0, NA)) +
  labs(title = "B. Donation share of gross income: flat",
       subtitle = "Denominator growth masks the dollar increase in Panel A",
       x = "Years relative to DGR endorsement", y = "Donation share",
       colour = NULL) +
  theme_minimal() + theme(legend.position = "bottom")

# Panel C: pre vs post share by baseline dependence group
pc <- dep |>
  mutate(period = factor(period, c("pre", "post"), c("Pre", "Post")),
         baseline_group = factor(baseline_group,
                                 c("low (<10%)", "mid (10-50%)", "high (>50%)"))) |>
  ggplot(aes(baseline_group, mean_share, fill = period)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.6) +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "C. Pre vs post by baseline donation dependence",
       subtitle = "Low/mid-dependence charities gain; high group regresses down",
       x = "Baseline (pre-endorsement) donation dependence",
       y = "Mean donation share", fill = NULL) +
  theme_minimal() + theme(legend.position = "bottom")

# Panel D defined above (three-cohort within-charity growth bars).

if (requireNamespace("patchwork", quietly = TRUE)) {
  library(patchwork)
  combined <- (pa | pb) / (pc | pd) +
    plot_annotation(
      title = "Donations around DGR endorsement — 646 established switchers, 2020-23 cohorts",
      caption = "Source: ACNC AIS 2019-2024 x ABR endorsement dates. Real = FY2019 dollars (ABS 6401 CPI)."
    )
  ggsave(file.path(out_dir, "event_study_summary.png"), combined,
         width = 12, height = 10, dpi = 150)
} else {
  ggsave(file.path(out_dir, "summary_A_levels.png"), pa, width = 6, height = 5, dpi = 150)
  ggsave(file.path(out_dir, "summary_B_share.png"),  pb, width = 6, height = 5, dpi = 150)
  ggsave(file.path(out_dir, "summary_C_dependence.png"), pc, width = 6, height = 5, dpi = 150)
  ggsave(file.path(out_dir, "summary_D_three_cohort.png"), pd, width = 6, height = 5, dpi = 150)
}
message("Plots written to analysis/dgr_event_study/")
