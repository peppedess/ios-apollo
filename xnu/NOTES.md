
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

## 1278 — sessantaquattro blocchi, e un nome per il 5

Due risultati da k123.

**Il formato del log del firmware.** Un blocco si apre con dieci parole di
intestazione, la nona è un timestamp assoluto; poi i record, separati dal
marcatore `0x07000000`: timestamp relativo, un header il cui byte basso è il
numero di argomenti per quattro, e gli argomenti. Diversi argomenti sono
**puntatori alle tabelle di stringhe del firmware**, quindi i record si
leggono: il primo risolto dice `WAL_PM_ARB_REQ_ID_WAL_CLIENT`. Il record
`0x11defb08` è "comando WMI ricevuto" e porta l'id: `0x4003` per ogni
scrittura di parametro della raffica, `0x5003` per il vdev start.
Il decodificatore sta in `/tmp/claude-0/fwl.py`.

**Il 5 ha un nome.** Non è l'enum pubblico degli stati di vdev start, che si
ferma a quattro. È `A_STATUS` di Atheros (`athdefs.h`): `-1 = A_ERROR`, che è
quello che tornavano le due prove iniziali senza peer, e **`5 = A_BAD_ADDRESS`,
"address does not match descriptor"**. Con il peer creato il firmware smette di
dare l'errore generico e dice che un indirizzo non torna.

Restava un problema pratico: stampavamo otto blocchi e dopo lo sweep ne
arrivano sessantatré, di cui i primi ventisette sono residuo dello
svuotamento. Ora se ne stampano sessantaquattro.
