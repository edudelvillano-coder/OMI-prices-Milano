# ------------------------------------------------------------------
# 03_inflazione_e_robustezza.R
# 1) Affitti in termini reali (euro 2025) con l'indice FOI senza tabacchi
# 2) Controlli di robustezza: mediana invece di media, fascia suburbana
#    senza le zone E5 ed E6 (salto del 2022-S2)
#
# Input : data/clean/omi_milano_affitti.csv
#         data/external/istat_foi_mensile.csv
# Output: grafici in reports/figures/, tabelle in reports/tables/
#
# Nota sul deflatore: la serie FOI fino al 2025 e' nella vecchia base,
# dal 2026 nella base 2025 = 100. Porto tutto a base 2025 = 100
# dividendo la serie vecchia per la sua media 2025. E' un raccordo
# approssimato: verifica con il coefficiente ufficiale ISTAT.
# Fonti: Agenzia Entrate - OMI; ISTAT (indici FOI senza tabacchi)
# ------------------------------------------------------------------

library(readr)
library(dplyr)
library(tidyr)
library(stringr)
library(ggplot2)

dir.create("reports/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("reports/tables",  recursive = TRUE, showWarnings = FALSE)

fonte_reale <- "Fonte: Agenzia Entrate - OMI, ISTAT (FOI). Elaborazione propria. Euro 2025."

# 1. Deflatore semestrale --------------------------------------------
foi <- read_csv("data/external/istat_foi_mensile.csv", show_col_types = FALSE) %>%
  pivot_longer(starts_with("m"), names_to = "mese", names_prefix = "m",
               values_to = "indice") %>%
  mutate(mese = as.integer(mese)) %>%
  filter(!is.na(indice))

coef_raccordo <- foi %>%
  filter(base == "serie_precedente", anno == 2025) %>%
  summarise(m = mean(indice)) %>% pull(m)

defl <- foi %>%
  mutate(indice_2025 = if_else(base == "serie_precedente",
                               indice / coef_raccordo * 100, indice),
         semestre = if_else(mese <= 6, 1L, 2L)) %>%
  group_by(anno, semestre) %>%
  summarise(deflatore = mean(indice_2025), n_mesi = n(), .groups = "drop")

cat("Deflatore semestrale (base 2025 = 100):\n")
print(defl, n = Inf)
cat("Attenzione: l'ultimo semestre usa solo", min(defl$n_mesi),
    "mesi (2026-S1 = gennaio-maggio).\n")

# 2. Base di analisi (stessa logica dello script 02) ------------------
omi <- read_csv("data/clean/omi_milano_affitti.csv", show_col_types = FALSE)

base <- omi %>%
  filter(Cod_Tip == 20, Stato == "NORMALE", !is.na(loc_medio)) %>%
  mutate(
    data = as.Date(paste0(anno, if_else(semestre == 1, "-04-01", "-10-01"))),
    Fascia_lab = factor(Fascia, levels = c("B", "C", "D", "E", "R"),
                        labels = c("Centrale", "Semicentrale", "Periferica",
                                   "Suburbana", "Extraurbana"))
  ) %>%
  left_join(defl, by = c("anno", "semestre"))

if (anyNA(base$deflatore)) {
  stop("Deflatore mancante per alcuni semestri: ",
       paste(unique(base$periodo[is.na(base$deflatore)]), collapse = ", "))
}

base <- base %>% mutate(loc_reale = loc_medio / deflatore * 100)

n_sem <- n_distinct(base$periodo)
zone_stabili <- base %>%
  distinct(LinkZona, periodo) %>% count(LinkZona) %>%
  filter(n == n_sem) %>% pull(LinkZona)
stabili <- base %>% filter(LinkZona %in% zone_stabili)

primo  <- min(stabili$data)
ultimo <- max(stabili$data)
anni   <- as.numeric(ultimo - primo) / 365.25

# 3. Affitti reali per fascia -----------------------------------------
serie_reale <- stabili %>%
  group_by(data, Fascia_lab) %>%
  summarise(nominale = mean(loc_medio), reale = mean(loc_reale),
            .groups = "drop")

g5 <- ggplot(serie_reale, aes(data, reale, colour = Fascia_lab)) +
  geom_line(linewidth = 1) + geom_point(size = 1.5) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  labs(title = "Affitto medio per fascia in termini reali",
       subtitle = "Abitazioni civili, stato normale (euro 2025/mq al mese)",
       x = NULL, y = "euro 2025/mq al mese", colour = "Fascia",
       caption = fonte_reale) +
  theme_minimal(base_size = 12)
ggsave("reports/figures/05_affitto_reale_per_fascia.png", g5,
       width = 9, height = 5.5, dpi = 200, bg = "white")

# Nominale vs reale: confronto sul primo e ultimo semestre
tab_reale <- serie_reale %>%
  filter(data %in% c(primo, ultimo)) %>%
  mutate(tempo = if_else(data == primo, "inizio", "fine")) %>%
  select(Fascia_lab, tempo, nominale, reale) %>%
  pivot_wider(names_from = tempo, values_from = c(nominale, reale)) %>%
  mutate(
    var_nominale_pct  = (nominale_fine / nominale_inizio - 1) * 100,
    var_reale_pct     = (reale_fine / reale_inizio - 1) * 100,
    crescita_annua_reale_pct = ((reale_fine / reale_inizio)^(1 / anni) - 1) * 100,
    var_assoluta_nominale_eur = nominale_fine - nominale_inizio
  ) %>%
  mutate(across(where(is.numeric), ~ round(.x, 1)))
cat("\nVariazione nominale e reale per fascia:\n")
print(tab_reale, width = Inf)
write_csv(tab_reale, "reports/tables/variazione_nominale_reale.csv")

# Rapporto centro/periferia in termini reali e' identico al nominale
# (il deflatore si semplifica): non serve rifarlo.

# 4. Robustezza: mediana invece di media ------------------------------
conf <- stabili %>%
  filter(data %in% c(primo, ultimo)) %>%
  mutate(tempo = if_else(data == primo, "inizio", "fine")) %>%
  group_by(Fascia_lab, tempo) %>%
  summarise(media = mean(loc_medio), mediana = median(loc_medio),
            n_zone = n(), .groups = "drop") %>%
  pivot_wider(names_from = tempo, values_from = c(media, mediana)) %>%
  mutate(var_media_pct   = (media_fine / media_inizio - 1) * 100,
         var_mediana_pct = (mediana_fine / mediana_inizio - 1) * 100) %>%
  mutate(across(where(is.numeric), ~ round(.x, 1)))
cat("\nMedia vs mediana tra zone (nominale):\n")
print(conf, width = Inf)
write_csv(conf, "reports/tables/robustezza_media_mediana.csv")

# 5. Fascia suburbana: effetto di E5 ed E6 ----------------------------
cat("\nSerie delle zone E5 ed E6 (euro/mq nominali):\n")
stabili %>%
  filter(Zona %in% c("E5", "E6")) %>%
  select(periodo, Zona, loc_medio) %>%
  pivot_wider(names_from = Zona, values_from = loc_medio) %>%
  print(n = Inf)

sub_conf <- stabili %>%
  filter(Fascia_lab == "Suburbana") %>%
  mutate(gruppo = if_else(Zona %in% c("E5", "E6"), "E5+E6", "altre suburbane")) %>%
  group_by(data, gruppo) %>%
  summarise(affitto = mean(loc_medio), .groups = "drop")

g6 <- ggplot(sub_conf, aes(data, affitto, colour = gruppo)) +
  geom_line(linewidth = 1) + geom_point(size = 1.5) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  labs(title = "Fascia suburbana: il salto del 2022 viene da E5 ed E6",
       subtitle = "Affitto medio nominale (euro/mq al mese)",
       x = NULL, y = "euro/mq al mese", colour = NULL,
       caption = "Fonte: Agenzia Entrate - OMI. Elaborazione propria. Valori nominali.") +
  theme_minimal(base_size = 12)
ggsave("reports/figures/06_suburbana_e5_e6.png", g6,
       width = 9, height = 5, dpi = 200, bg = "white")

cat("\nFatto. Nuovi grafici 05 e 06 in reports/figures/, tabelle in reports/tables/\n")
