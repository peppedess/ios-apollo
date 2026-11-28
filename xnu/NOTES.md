
## 1276 — scaricare il log con quattrocento scritture

k121 ha mostrato la forma del problema. A 75.519 il firmware ha spedito **sette
blocchi** del proprio log, undici millisecondi dopo che il primo peer setup gli
aveva consegnato le code di riordino. Quindi lo spedisce. Poi è partito lo
sweep, otto vdev start tutti con stato 5, e dopo non è arrivato più niente: i
record sui rifiuti sono rimasti nel buffer del firmware, perché quel buffer
parte quando è pieno, e otto comandi non riempiono 1,5 KiB.

Rimandare la raffica delle code di riordino non è servito, e adesso si capisce
perché: la prima volta creava stato nuovo e il firmware ci scriveva sopra a
lungo, la seconda era un no-op. Il lavoro deve essere lavoro ogni volta.
Quattrocento `WMI_PDEV_SET_PARAM` che scrivono la larghezza di banda dinamica
al valore che ha già sono innocue, e ognuna è un comando che il firmware legge,
smista e annota. Il buffer si riempie molte volte, e la prima cosa che esce è
quello che il firmware ha scritto mentre rifiutava di avviare il vdev.

Nota di metodo: i sette blocchi di k121 contenevano il racconto del peer setup
e sono stati buttati, perché lo stampatore si arma solo allo sweep. Va bene
così: il budget di otto blocchi va speso su quello che esce **dopo** lo sweep.

## 1277 — svuotare la coda *prima*, non dopo

k122 ha risposto alla domanda su cui tre run si erano arenati: il firmware il
log lo spedisce, e quattrocento scritture innocue gliene fanno spedire tanto —
**centoquindici blocchi**. Ma spedisce prima il blocco **più vecchio**, e
nell'anello c'è un arretrato lungo che parte dall'avvio. Gli otto blocchi che
abbiamo stampato erano record del tempo firmware 0x14a. I vdev start stavano
intorno al blocco centodieci: ricevuti e buttati.

Quindi prima si svuota. Quattrocento scritture **prima** dello sweep, con lo
stampatore ancora disarmato, vuotano l'anello; poi si arma, poi lo sweep, poi
altre quattrocento. Il primo blocco che esce adesso contiene il residuo, gli
otto avvii rifiutati e l'inizio della seconda raffica.

La raffica è diventata `wifi_fwlog_churn()`, e `sweetfwlog` si legge da
`fwlog_wanted()` così lo svuotamento e lo stampatore sono d'accordo su chi sta
ascoltando.
