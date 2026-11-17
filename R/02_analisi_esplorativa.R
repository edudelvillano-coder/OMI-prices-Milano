install.packages(c("forcats","ggplot2","scales"))
install.packages("tidyr")

# ------------------------------------------------------------------
# 02_analisi_esplorativa.R
# Analisi esplorativa dell'andamento degli affitti a Milano (OMI).
#
# Input : data/clean/omi_milano_affitti.csv  (prodotto da 01_import_omi.R)
# Output: grafici in reports/figures/ e tabelle in reports/tables/
#
# Scelte di metodo (da riportare nel README):
#  - tipologia: abitazioni civili (Cod_Tip 20), stato di conservazione NORMALE
#  - affitto = punto medio dell'intervallo OMI (euro/mq al mese, valori nominali)
#  - per i confronti nel tempo uso solo le zone presenti in tutti i semestri,
#    cosi' non confronto aree diverse
#  - le medie per fascia sono medie semplici tra zone (non pesate)
# Fonte dei dati: Agenzia Entrate - OMI
# ------------------------------------------------------------------

library(readr)
library(dplyr)
library(tidyr)
library(stringr)
library(forcats)
library(ggplot2)
library(scales)

dir.create("reports/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("reports/tables",  recursive = TRUE, showWarnings = FALSE)

omi <- read_csv("data/clean/omi_milano_affitti.csv", show_col_types = FALSE)

fonte <- "Fonte: Agenzia Entrate - OMI. Elaborazione propria. Valori nominali."

# 1. Base di analisi -------------------------------------------------
base <- omi %>%
  filter(Cod_Tip == 20, Stato == "NORMALE", !is.na(loc_medio)) %>%
  mutate(
    data = as.Date(paste0(anno, if_else(semestre == 1, "-04-01", "-10-01"))),
    Fascia_lab = factor(
      Fascia,
      levels = c("B", "C", "D", "E", "R"),
      labels = c("Centrale", "Semicentrale", "Periferica",
                 "Suburbana", "Extraurbana")
    )
  )

# 2. Controlli sui dati ----------------------------------------------
n_sem <- n_distinct(base$periodo)
cat("Semestri:", n_sem, "| Zone totali:", n_distinct(base$LinkZona), "\n")

zone_stabili <- base %>%
  distinct(LinkZona, periodo) %>%
  count(LinkZona) %>%
  filter(n == n_sem) %>%
  pull(LinkZona)
cat("Zone presenti in tutti i semestri:", length(zone_stabili), "\n")

cambi_fascia <- base %>%
  distinct(LinkZona, Fascia) %>%
  count(LinkZona) %>%
  filter(n > 1)
cat("Zone che hanno cambiato fascia nel tempo:", nrow(cambi_fascia), "\n")

stabili <- base %>% filter(LinkZona %in% zone_stabili)

# Salti anomali da un semestre al successivo (possibili errori nei dati)
salti <- stabili %>%
  arrange(LinkZona, data) %>%
  group_by(LinkZona) %>%
  mutate(var_sem = loc_medio / lag(loc_medio) - 1) %>%
  ungroup() %>%
  filter(!is.na(var_sem))
cat("\nI 10 salti semestrali piu' grandi (in valore assoluto):\n")
salti %>%
  slice_max(abs(var_sem), n = 10) %>%
  transmute(periodo, Zona, Zona_Descr = str_trunc(Zona_Descr, 40),
            loc_medio, var_sem_pct = round(var_sem * 100, 1)) %>%
  print(n = 10)

# 3. Andamento per fascia --------------------------------------------
serie_fascia <- stabili %>%
  group_by(data, periodo, Fascia_lab) %>%
  summarise(affitto = mean(loc_medio), n_zone = n(), .groups = "drop")

g1 <- ggplot(serie_fascia, aes(data, affitto, colour = Fascia_lab)) +
  geom_line(linewidth = 1) +
  geom_point(size = 1.5) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  scale_y_continuous(labels = label_number(accuracy = 1)) +
  labs(title = "Affitto medio per fascia, Milano",
       subtitle = "Abitazioni civili, stato normale (euro/mq al mese)",
       x = NULL, y = "euro/mq al mese", colour = "Fascia", caption = fonte) +
  theme_minimal(base_size = 12)
ggsave("reports/figures/01_affitto_per_fascia.png", g1,
       width = 9, height = 5.5, dpi = 200, bg = "white")

# 4. Numeri indice (primo semestre = 100) ----------------------------
indice <- serie_fascia %>%
  group_by(Fascia_lab) %>%
  arrange(data, .by_group = TRUE) %>%
  mutate(indice = affitto / first(affitto) * 100) %>%
  ungroup()

g2 <- ggplot(indice, aes(data, indice, colour = Fascia_lab)) +
  geom_hline(yintercept = 100, linetype = "dashed", colour = "grey60") +
  geom_line(linewidth = 1) +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  labs(title = "Crescita degli affitti per fascia",
       subtitle = "Numero indice, primo semestre disponibile = 100",
       x = NULL, y = "indice", colour = "Fascia", caption = fonte) +
  theme_minimal(base_size = 12)
ggsave("reports/figures/02_indice_per_fascia.png", g2,
       width = 9, height = 5.5, dpi = 200, bg = "white")

# 5. Tabella riassuntiva: primo vs ultimo semestre -------------------
primo  <- min(stabili$data)
ultimo <- max(stabili$data)
anni   <- as.numeric(ultimo - primo) / 365.25

tab_fascia <- serie_fascia %>%
  filter(data %in% c(primo, ultimo)) %>%
  mutate(tempo = if_else(data == primo, "inizio", "fine")) %>%
  select(Fascia_lab, tempo, affitto) %>%
  pivot_wider(names_from = tempo, values_from = affitto) %>%
  mutate(variazione_pct       = (fine / inizio - 1) * 100,
         crescita_annua_pct   = ((fine / inizio)^(1 / anni) - 1) * 100) %>%
  mutate(across(where(is.numeric), ~ round(.x, 1)))
print(tab_fascia)
write_csv(tab_fascia, "reports/tables/variazione_per_fascia.csv")

# 6. Zone che sono cresciute di piu' e di meno -----------------------
var_zone <- stabili %>%
  filter(data %in% c(primo, ultimo)) %>%
  mutate(tempo = if_else(data == primo, "inizio", "fine")) %>%
  select(LinkZona, Zona, Zona_Descr, Fascia_lab, tempo, loc_medio) %>%
  pivot_wider(names_from = tempo, values_from = loc_medio) %>%
  mutate(var_pct = (fine / inizio - 1) * 100)

estremi <- bind_rows(slice_max(var_zone, var_pct, n = 8),
                     slice_min(var_zone, var_pct, n = 8)) %>%
  mutate(etichetta = paste0(Zona, " - ", str_trunc(coalesce(Zona_Descr, ""), 40)),
         etichetta = fct_reorder(etichetta, var_pct))

g3 <- ggplot(estremi, aes(var_pct, etichetta, fill = Fascia_lab)) +
  geom_col() +
  labs(title = "Zone con la crescita maggiore e minore degli affitti",
       subtitle = "Variazione % tra il primo e l'ultimo semestre disponibile",
       x = "variazione %", y = NULL, fill = "Fascia", caption = fonte) +
  theme_minimal(base_size = 11)
ggsave("reports/figures/03_zone_estreme.png", g3,
       width = 10, height = 6, dpi = 200, bg = "white")

# 7. Il divario tra centro e periferia -------------------------------
rapporto <- serie_fascia %>%
  filter(Fascia_lab %in% c("Centrale", "Periferica")) %>%
  select(data, Fascia_lab, affitto) %>%
  pivot_wider(names_from = Fascia_lab, values_from = affitto) %>%
  mutate(rapporto = Centrale / Periferica)

g4 <- ggplot(rapporto, aes(data, rapporto)) +
  geom_line(linewidth = 1, colour = "#2c7fb8") +
  geom_point(size = 1.5, colour = "#2c7fb8") +
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  labs(title = "Quante volte costa il centro rispetto alla periferia",
       subtitle = "Rapporto tra affitto medio in fascia centrale e periferica",
       x = NULL, y = "rapporto", caption = fonte) +
  theme_minimal(base_size = 12)
ggsave("reports/figures/04_rapporto_centro_periferia.png", g4,
       width = 9, height = 5, dpi = 200, bg = "white")

cat("\nFatto. Grafici in reports/figures/, tabella in reports/tables/\n")
