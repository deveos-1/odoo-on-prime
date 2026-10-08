# Deploy di Odoo 18.0 multi-tenant su Render.com (piani Free)

Questo repository contiene Odoo (community) con un livello di infrastruttura
(`infra/`, `Dockerfile`, `render.yaml`) pensato per un deploy "production-like"
multi-tenant (multi-azienda/multi-cliente) interamente su piani **Free** di
Render.

## Architettura multi-tenant

- **Un solo servizio web Odoo** + **un solo database Postgres condiviso**.
- Ogni tenant = **un database Postgres separato** sullo stesso server
  (`CREATE DATABASE <tenant>`), non un deploy separato: è l'approccio
  standard usato da Odoo.sh/Odoo SaaS.
- Il routing verso il database giusto avviene con `dbfilter = ^%d$`
  (variabile `ODOO_DBFILTER`): Odoo estrae il subdominio dall'header `Host`
  (grazie a `proxy_mode = True`, necessario dietro il proxy TLS di Render) e
  seleziona il database con lo stesso nome.
- `list_db = False`: il selettore/gestore database è disattivato in
  produzione (riduce la superficie di attacco: niente elenco/duplica/
  elimina DB via web).
- Gli allegati (`ir.attachment`) vengono forzati nel DB
  (`ir_attachment.location = db`) perché **i web service Free di Render non
  hanno disco persistente**: qualunque file scritto su `/var/lib/odoo`
  sparisce ad ogni redeploy/restart/cold start.

## Limiti dei piani Free di Render (da conoscere PRIMA di andare in produzione)

| Risorsa | Limite Free | Impatto su Odoo |
|---|---|---|
| Web service Free | 512 MB RAM, 0.1 CPU | `workers=0` (modalità threaded) per restare sotto il limite; con molti tenant/utenti concorrenti andrà sotto stress |
| Web service Free | **Si spegne dopo 15 min di inattività** | Cold start lento (Odoo carica il registry di tutti i moduli): la prima richiesta dopo lo sleep può impiegare 30-60s+ |
| Postgres Free | 1 GB storage | Sufficiente solo per pochi tenant piccoli/demo |
| Postgres Free | **Scade dopo 30 giorni** (va ricreato/migrato) | Serve un piano a pagamento per continuità reale in produzione |
| Nessun disco persistente su web Free | — | Filestore forzato nel DB (vedi sopra); niente backup locali su filesystem |
| Nessun dominio wildcard gratuito | — | `*.onrender.com` non supporta wildcard: per il routing per-subdominio reale serve un dominio custom tuo con DNS wildcard (`*.tuodominio.com` CNAME verso il servizio Render) |

> In sintesi: questa configurazione è pensata per **dimostrare/validare**
> un'architettura multi-tenant production-grade. Per un uso realmente in
> produzione con più clienti attivi, upgrada almeno il Postgres (piano a
> pagamento, niente scadenza 30gg) e il web service (piano con RAM >=2GB e
> disco, o più istanze).

## Deploy

1. **Postgres** (free, Frankfurt) creato su Render: `odoo-saas-db`.
2. **Web service Docker** (free, Frankfurt) creato su Render: `odoo-saas`,
   puntato su questo repository, `Dockerfile` alla radice.
3. Variabili d'ambiente principali (vedi anche `render.yaml`):
   - `DATABASE_URL`: collegata automaticamente al Postgres Render.
   - `ODOO_MASTER_PASSWORD`: master password per operazioni di gestione DB
     (generata automaticamente da Render, non riusarla altrove).
   - `ODOO_DBFILTER = ^%d$`
   - `ODOO_LIST_DB = False`
   - `ODOO_WORKERS = 0`

## Creare un nuovo tenant

Dopo il primo deploy, apri una shell sul servizio Render (`Shell` nel
dashboard del servizio web) ed esegui:

```bash
python3 infra/create_tenant.py --name acme --admin-password 'Str0ngPass!'
```

Questo:
1. Crea il database Postgres `acme`.
2. Inizializza Odoo (`-i base`, senza demo data).
3. Imposta la password dell'utente `admin` e forza gli allegati nel DB.

Poi collega il subdominio `acme.<tuodominio>` (CNAME) al servizio Render e
aggiungilo come Custom Domain nel dashboard del servizio. Odoo instraderà
automaticamente le richieste su quel subdominio verso il database `acme`
grazie a `dbfilter`.

Senza un dominio custom (solo `*.onrender.com`), non è possibile fare routing
per-subdominio: in quel caso imposta temporaneamente `ODOO_LIST_DB=True` e
seleziona il tenant dal selettore database di Odoo (meno isolato, solo per
test/demo).

## Sicurezza

- `admin_passwd` (master password) non è mai loggata in chiaro nei file di
  configurazione committati: viene generata/iniettata solo a runtime via
  variabile d'ambiente Render.
- `list_db = False` in produzione.
- Ricorda di ruotare `ODOO_MASTER_PASSWORD` e le password admin dei tenant
  periodicamente.
