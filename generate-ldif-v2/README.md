# generate-ldif-v2

Strumenti operativi per gestire utenti e gruppi LDAP custom in `viya4-openldap`.

Questa directory contiene i file e gli script per:
- generare nuovi utenti/gruppi custom da YAML
- applicare modifiche incrementalmente su LDAP
- esportare utenti/gruppi custom da un LDAP vivo
- importare un export custom in un nuovo ambiente LDAP bootstrapato

> Il flusso operativo completo e i comandi di verifica/manutenzione sono documentati in `../GUIDE.md`.

## File presenti

### Configurazione e input
- `.env.example`  
  Template delle variabili di ambiente usate dagli script.
- `.env`  
  File reale locale con namespace, DN, credenziali e parametri runtime. **Non versionare.**
- `directory.yaml.template`  
  Template del modello dati utenti/gruppi.
- `directory.yaml`  
  File reale con utenti/gruppi custom da creare o aggiornare. **Non versionare.**

### Script
- `bin/generate.sh`  
  Legge `directory.yaml` e genera i file intermedi (`generated/`). Se `password` manca nello YAML, genera una password random e la converte in hash SSHA.
- `bin/apply.sh`  
  Applica incrementalmente utenti e gruppi su LDAP via `kubectl exec`. Mostra a video le password generate solo per utenti nuovi.
- `bin/export.sh`  
  Esegue un export dal LDAP vivo e produce `export-no-root.ldif`, escludendo utenti e gruppi di default creati dal deploy base.
- `bin/import.sh`  
  Importa un file LDIF già pronto nel LDAP target usando `ldapadd` o `ldapmodify`.

### Output / file generati
- `generated/users.tsv`  
  Tabella tecnica con utenti generati, inclusi hash e password temporanee della singola run.
- `generated/groups.tsv`  
  Tabella tecnica con gruppi e membership generate.
- `generated/users.preview.ldif`  
  Preview LDIF degli utenti custom.
- `generated/groups.preview.ldif`  
  Preview LDIF dei gruppi custom.
- `generated/plan.txt`  
  Riepilogo della generazione.
- `export-no-root.ldif`  
  Export live di utenti/gruppi custom da trasferire in un altro ambiente. **Non versionare.**

## File da non versionare

Sono esclusi da git perché contengono dati reali, hash password o credenziali:
- `.env`
- `directory.yaml`
- `directory.yaml_old`
- `user.ldif`
- `export-no-root.ldif`
- tutto `generated/`

## Uso minimo

### Generazione + apply incrementale
```bash
./bin/generate.sh
./bin/apply.sh
```

### Export da LDAP vivo
```bash
./bin/export.sh
```

### Import in un altro ambiente
```bash
./bin/import.sh ./export-no-root.ldif add
```

- `directory.yaml`
- `directory.yaml_old`
- `export-no-root.ldif`
- tutto `generated/`

## Uso minimo

### Generazione + apply incrementale
```bash
./bin/generate.sh
./bin/apply.sh
```

### Export da LDAP vivo
```bash
./bin/export.sh
```

### Import in un altro ambiente
```bash
./bin/import.sh ./export-no-root.ldif add
```
