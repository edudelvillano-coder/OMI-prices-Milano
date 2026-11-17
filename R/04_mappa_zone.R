# ------------------------------------------------------------------
# 04_mappa_zone.R
# Mappa delle zone OMI di Milano: variazione reale degli affitti e
# livello dell'affitto nell'ultimo semestre.
#
# Input : data/clean/omi_milano_affitti.csv
#         data/external/istat_foi_mensile.csv
#         data/raw/geo/  -> file dei perimetri di zona OMI (.kml, .geojson o .shp)
# Output: reports/figures/07_mappa_variazione_reale.png
#         reports/figures/08_mappa_livello_affitti.png
#         reports/tables/variazione_per_zona.csv
#
# Lo script non conosce in anticipo i nomi dei campi del file dei
# perimetri: prova a riconoscere da solo quale colonna contiene il
# codice di zona (LinkZona tipo MI00003228, oppure Zona tipo B12).
# Se non ci riesce si ferma e stampa le colonne trovate.
#
# Fonte dei dati: Agenzia Entrate - OMI; ISTAT (FOI senza tabacchi)
# ------------------------------------------------------------------

library(sf)
library(readr)
library(dplyr)
library(tidyr)
library(stringr)
library(purrr)
library(ggplot2)

dir.create("reports/figures", recursive = TRUE, showWarnings = FALSE)
dir.create("reports/tables",  recursive = TRUE, showWarnings = FALSE)

# 1. Perimetri -------------------------------------------------------
file_geo <- list.files("data/raw/geo", pattern = "\\.(kml|geojson|shp)$",
                       full.names = TRUE, ignore.case = TRUE)
if (length(file_geo) == 0) {
  stop("Nessun file .kml/.geojson/.shp in data/raw/geo/ (cartella di lavoro: ",
       getwd(), "). Se hai un .kmz, rinominalo in .zip, estrailo e usa il .kml dentro.")
}
f <- sort(file_geo, decreasing = TRUE)[1]
cat("Perimetri letti da:", f, "\n")

strati <- st_layers(f)$name
cat("Strati nel file:", paste(strati, collapse = ", "), "\n")

geo <- strati %>%
  map(~ st_zm(st_read(f, layer = .x, quiet = TRUE))) %>%
  bind_rows()
geo <- geo[!st_is_empty(geo), ]
cat("Poligoni letti:", nrow(geo), "\n")

# 2. Dati OMI --------------------------------------------------------
omi <- read_csv("data/clean/omi_milano_affitti.csv", show_col_types = FALSE)

base <- omi %>%
  filter(Cod_Tip == 20, Stato == "NORMALE", !is.na(loc_medio)) %>%
  mutate(data = as.Date(paste0(anno, if_else(semestre == 1, "-04-01", "-10-01"))),
         Fascia_lab = factor(Fascia, levels = c("B", "C", "D", "E", "R"),
                             labels = c("Centrale", "Semicentrale", "Periferica",
                                        "Suburbana", "Extraurbana")))

n_sem <- n_distinct(base$periodo)
zone_stabili <- base %>% distinct(LinkZona, periodo) %>% count(LinkZona) %>%
  filter(n == n_sem) %>% pull(LinkZona)

primo  <- min(base$data)
ultimo <- max(base$data)
r1 <- base %>% filter(data == primo)  %>% slice(1)
r2 <- base %>% filter(data == ultimo) %>% slice(1)

# Inflazione cumulata tra primo e ultimo semestre (stesso deflatore dello script 03)
foi <- read_csv("data/external/istat_foi_mensile.csv", show_col_types = FALSE) %>%
  pivot_longer(starts_with("m"), names_to = "mese", names_prefix = "m",
               values_to = "indice") %>%
  mutate(mese = as.integer(mese)) %>% filter(!is.na(indice))
coef_raccordo <- foi %>% filter(base == "serie_precedente", anno == 2025) %>%
  summarise(m = mean(indice)) %>% pull(m)
defl <- foi %>%
  mutate(indice_2025 = if_else(base == "serie_precedente",
                               indice / coef_raccordo * 100, indice),
         semestre = if_else(mese <= 6, 1L, 2L)) %>%
  group_by(anno, semestre) %>% summarise(d = mean(indice_2025), .groups = "drop")
d1 <- defl$d[defl$anno == r1$anno & defl$semestre == r1$semestre]
d2 <- defl$d[defl$anno == r2$anno & defl$semestre == r2$semestre]
inflazione <- d2 / d1
cat("Inflazione cumulata", r1$periodo, "->", r2$periodo, ":",
    round((inflazione - 1) * 100, 1), "%\n")

var_zone <- base %>%
  filter(LinkZona %in% zone_stabili, data %in% c(primo, ultimo)) %>%
  mutate(tempo = if_else(data == primo, "inizio", "fine")) %>%
  select(LinkZona, Zona, Zona_Descr, Fascia_lab, tempo, loc_medio) %>%
  pivot_wider(names_from = tempo, values_from = loc_medio) %>%
  mutate(var_nominale_pct = (fine / inizio - 1) * 100,
         var_reale_pct    = ((fine / inizio) / inflazione - 1) * 100)

# 3. Riconoscimento della colonna di collegamento --------------------
attr_geo <- st_drop_geometry(geo)
chiavi_omi <- list(LinkZona = unique(omi$LinkZona), Zona = unique(omi$Zona))

valori_chiave <- function(col, chiave) {
  v <- toupper(str_trim(as.character(attr_geo[[col]])))
  if (chiave == "LinkZona") v <- str_extract(v, "MI\\d{8}")
  v
}
punteggi <- expand_grid(col = names(attr_geo), chiave = names(chiavi_omi)) %>%
  mutate(quota = map2_dbl(col, chiave, function(col, chiave) {
    mean(valori_chiave(col, chiave) %in% toupper(chiavi_omi[[chiave]]))
  })) %>%
  # a parita' di corrispondenza preferisco LinkZona: e' piu' stabile del
  # codice breve (B12), che puo' essere riassegnato tra un semestre e l'altro
  arrange(desc(round(quota, 2)), desc(chiave == "LinkZona"))
print(head(punteggi, 5))

migliore <- punteggi[1, ]
if (migliore$quota < 0.3) {
  cat("\nNon riconosco il codice di zona. Colonne del file dei perimetri:\n")
  print(names(attr_geo))
  print(head(attr_geo, 5))
  stop("Incolla in chat l'output qui sopra e adatto lo script.")
}
cat("Collegamento via colonna '", migliore$col, "' = ", migliore$chiave,
    " (", round(migliore$quota * 100), "% delle righe)\n", sep = "")

geo$chiave_geo <- valori_chiave(migliore$col, migliore$chiave)
var_zone$chiave_geo <- toupper(var_zone[[migliore$chiave]])

# tengo solo i poligoni delle zone di Milano presenti nei dati OMI
geo <- geo %>% filter(chiave_geo %in% toupper(chiavi_omi[[migliore$chiave]]))

# un solo poligono per zona (se il file ne ha piu' di uno, li unisco)
n_prima <- nrow(geo)
geo <- geo %>% group_by(chiave_geo) %>% summarise(.groups = "drop")
if (nrow(geo) < n_prima) {
  cat("Elementi del file uniti per avere un poligono per zona:",
      n_prima, "->", nrow(geo), "\n")
}
mappa <- geo %>% left_join(var_zone, by = "chiave_geo")

cat("Poligoni di Milano:", nrow(mappa),
    "| con dato di variazione:", sum(!is.na(mappa$var_reale_pct)), "\n")
cat("Zone senza poligono:",
    paste(setdiff(var_zone$chiave_geo, mappa$chiave_geo), collapse = ", "), "\n")

write_csv(var_zone %>% select(-chiave_geo) %>% arrange(desc(var_reale_pct)),
          "reports/tables/variazione_per_zona.csv")

# 4. Mappe -----------------------------------------------------------
fonte <- "Fonte: Agenzia Entrate - OMI, ISTAT (FOI). Elaborazione propria."
periodo_txt <- paste(r1$periodo, "-", r2$periodo)

# proietto in UTM 32N (metri): niente avvisi sui centroidi e mappa meno distorta
mappa <- st_transform(mappa, 32632)
etichette <- mappa %>% filter(!is.na(Zona))

m1 <- ggplot(mappa) +
  geom_sf(aes(fill = var_reale_pct), colour = "white", linewidth = 0.2) +
  geom_sf_text(data = etichette, aes(label = Zona),
               size = 2.3, colour = "grey15", check_overlap = TRUE) +
  scale_fill_viridis_c(option = "C", na.value = "grey85",
                       name = "Variazione\nreale %") +
  labs(title = "Dove sono cresciuti di piu' gli affitti a Milano",
       subtitle = paste0("Variazione reale dell'affitto, ", periodo_txt,
                         ". Grigio: zona non confrontabile nel tempo"),
       caption = fonte) +
  theme_void(base_size = 12) +
  theme(plot.margin = margin(10, 10, 10, 10))
ggsave("reports/figures/07_mappa_variazione_reale.png", m1,
       width = 9, height = 8, dpi = 200, bg = "white")

m2 <- ggplot(mappa) +
  geom_sf(aes(fill = fine), colour = "white", linewidth = 0.2) +
  scale_fill_viridis_c(option = "D", na.value = "grey85",
                       name = "euro/mq\nal mese") +
  labs(title = "Affitto medio per zona",
       subtitle = paste0("Abitazioni civili, stato normale, ", r2$periodo,
                         " (valori nominali)"),
       caption = fonte) +
  theme_void(base_size = 12) +
  theme(plot.margin = margin(10, 10, 10, 10))
ggsave("reports/figures/08_mappa_livello_affitti.png", m2,
       width = 9, height = 8, dpi = 200, bg = "white")

cat("\nFatto. Mappe 07 e 08 in reports/figures/, tabella per zona in reports/tables/\n")
