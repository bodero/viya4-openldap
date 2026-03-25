# OpenLDAP Migration & Operations Guide

Guida operativa consolidata per `viya4-openldap` e `generate-ldif-v2`.

> In questa guida non sono riportati account reali oltre a quelli di default creati dal deploy base.

---

## Prerequisiti di riferimento

- URI LDAP: `ldap://localhost:1389`
- Admin DN: `cn=admin,dc=sasldap,dc=com`
- Base DN: `dc=sasldap,dc=com`
- OU utenti: `ou=users,dc=sasldap,dc=com`
- OU gruppi: `ou=groups,dc=sasldap,dc=com`

---

# 1) Deploy nuovo LDAP + creazione struttura base

```bash
./viya4-openldap.sh --namespace sasldap --deploy-structure --verbose
```

## Oggetti di default creati

### Utenti di default
- `sasbind`
- `sas`
- `cas`
- `sasadm`
- `sasdev`
- `sasuser`

### Gruppi di default
- `sas`
- `sasadmins`
- `sasdevs`
- `sasusers`

## Verifiche utili

### Utenti presenti
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "dc=sasldap,dc=com" "(objectClass=posixAccount)" dn uid cn
```

### Gruppi presenti
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=groups,dc=sasldap,dc=com" "(objectClass=groupOfNames)" dn cn member
```

---

# 2) Creazione nuovi utenti e gruppi

Compilare `generate-ldif-v2/directory.yaml` a partire da `directory.yaml.template`.

## Esempio minimo

```yaml
uid_start: 7000
gid_start: 6000

users:
  - uid: user.name
    givenName: User
    sn: Name
    mail: user.name@example.com
    groups:
      - project-users

groups:
  - name: project-users
    members: []
```

## Generazione
```bash
./bin/generate.sh
```

## Apply incrementale
```bash
./bin/apply.sh
```

## Password
- se `password:` manca nello YAML, viene generata automaticamente durante `generate.sh`
- la password viene mostrata a video durante `apply.sh` solo per utenti nuovi realmente aggiunti

## Verifiche utili

### Verifica utente specifico
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=users,dc=sasldap,dc=com" "(uid=user.name)" dn uid cn mail
```

### Verifica gruppo specifico
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=groups,dc=sasldap,dc=com" "(cn=project-users)" dn cn member
```

---

# 3) Export da LDAP già operativo

`bin/export.sh` legge dal LDAP vivo e produce un file unico:
- `export-no-root.ldif`

Esclude gli oggetti di default creati dal deploy base.

## Comando
```bash
./bin/export.sh
```

## Output atteso
```bash
./export-no-root.ldif
```

## Utenti esclusi dall'export
- `sas`
- `cas`
- `sasadm`
- `sasdev`
- `sasuser`

## Gruppi esclusi dall'export
- `sas`
- `sasadmins`
- `sasdevs`
- `sasusers`

## Verifiche utili sull'export

### Elenco DN esportati
```bash
grep -n "^dn: " export-no-root.ldif
```

### Elenco membership esportate
```bash
grep -n "^member: " export-no-root.ldif
```

### Verifica che i default non compaiano
```bash
grep -nE 'uid=(sas|cas|sasadm|sasdev|sasuser)\b|cn=(sas|sasadmins|sasdevs|sasusers)\b' export-no-root.ldif
```

---

# 4) Import su nuovo LDAP dei soli utenti/gruppi custom

Prerequisito: il nuovo ambiente deve essere già stato bootstrapato con il deploy base.

## Comando
```bash
./bin/import.sh ./export-no-root.ldif add
```

## Comportamento
- usa `ldapadd -c`
- continua in presenza di duplicati
- mantiene login e password già presenti nell'LDIF esportato

## Verifiche utili dopo import

### Utenti custom presenti
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=users,dc=sasldap,dc=com" "(objectClass=posixAccount)" dn uid cn
```

### Gruppi custom presenti
```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=groups,dc=sasldap,dc=com" "(objectClass=groupOfNames)" dn cn member
```

---

# 5) Modificare password, utente o gruppo con `generate.sh` + `apply.sh`

## 5.1 Reset/modifica password utente esistente

Nel `directory.yaml` aggiungere `password:` all'utente:

```yaml
users:
  - uid: user.name
    givenName: User
    sn: Name
    mail: user.name@example.com
    password: TempReset!2026
    groups:
      - project-users

groups:
  - name: project-users
    members: []
```

Poi:
```bash
./bin/generate.sh
./bin/apply.sh
```

Dopo il reset, rimuovere `password:` se non si vuole lasciare il segreto nel file.

## 5.2 Modifica attributi utente
Aggiornare nel `directory.yaml` i campi desiderati, poi:

```bash
./bin/generate.sh
./bin/apply.sh
```

## 5.3 Aggiunta utente a gruppo esistente
Nel `directory.yaml`, aggiungere il gruppo in `users[].groups`, poi:

```bash
./bin/generate.sh
./bin/apply.sh
```

## 5.4 Creazione nuovo gruppo custom
Definire il gruppo in `groups:` e riferirlo negli utenti tramite `users[].groups`, poi:

```bash
./bin/generate.sh
./bin/apply.sh
```

---

# 6) Comandi utili di eliminazione / pulizia

## 6.1 Eliminazione singolo utente
```bash
ldapdelete -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  "uid=user.name,ou=users,dc=sasldap,dc=com"
```

## 6.2 Eliminazione singolo gruppo
```bash
ldapdelete -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  "cn=project-users,ou=groups,dc=sasldap,dc=com"
```

## 6.3 Eliminazione più utenti
```bash
cat > delete-users.txt <<'EOF'
uid=user.one,ou=users,dc=sasldap,dc=com
uid=user.two,ou=users,dc=sasldap,dc=com
EOF

while IFS= read -r dn; do
  [[ -n "$dn" ]] || continue
  ldapdelete -x -H ldap://localhost:1389 \
    -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
done < delete-users.txt
```

## 6.4 Eliminazione più gruppi
```bash
cat > delete-groups.txt <<'EOF'
cn=project-users,ou=groups,dc=sasldap,dc=com
cn=team-users,ou=groups,dc=sasldap,dc=com
EOF

while IFS= read -r dn; do
  [[ -n "$dn" ]] || continue
  ldapdelete -x -H ldap://localhost:1389 \
    -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
done < delete-groups.txt
```

## 6.5 Eliminare tutti gli utenti custom, esclusi i default
```bash
ldapsearch -x -LLL -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=users,dc=sasldap,dc=com" \
  '(&(objectClass=posixAccount)(!(uid=sas))(!(uid=cas))(!(uid=sasadm))(!(uid=sasdev))(!(uid=sasuser)))' dn \
| awk '/^dn: / {sub(/^dn: /, ""); print}' \
| while IFS= read -r dn; do
    [[ -n "$dn" ]] || continue
    ldapdelete -x -H ldap://localhost:1389 \
      -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
  done
```

## 6.6 Eliminare tutti i gruppi custom, esclusi i default
```bash
ldapsearch -x -LLL -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=groups,dc=sasldap,dc=com" \
  '(&(objectClass=groupOfNames)(!(cn=sas))(!(cn=sasadmins))(!(cn=sasdevs))(!(cn=sasusers)))' dn \
| awk '/^dn: / {sub(/^dn: /, ""); print}' \
| while IFS= read -r dn; do
    [[ -n "$dn" ]] || continue
    ldapdelete -x -H ldap://localhost:1389 \
      -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
  done
```

## 6.7 Ripulire interamente il custom LDAP (prima gruppi, poi utenti)

### Step A: gruppi custom
```bash
ldapsearch -x -LLL -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=groups,dc=sasldap,dc=com" \
  '(&(objectClass=groupOfNames)(!(cn=sas))(!(cn=sasadmins))(!(cn=sasdevs))(!(cn=sasusers)))' dn \
| awk '/^dn: / {sub(/^dn: /, ""); print}' \
| while IFS= read -r dn; do
    [[ -n "$dn" ]] || continue
    ldapdelete -x -H ldap://localhost:1389 \
      -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
  done
```

### Step B: utenti custom
```bash
ldapsearch -x -LLL -H ldap://localhost:1389 \
  -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' \
  -b "ou=users,dc=sasldap,dc=com" \
  '(&(objectClass=posixAccount)(!(uid=sas))(!(uid=cas))(!(uid=sasadm))(!(uid=sasdev))(!(uid=sasuser)))' dn \
| awk '/^dn: / {sub(/^dn: /, ""); print}' \
| while IFS= read -r dn; do
    [[ -n "$dn" ]] || continue
    ldapdelete -x -H ldap://localhost:1389 \
      -D "cn=admin,dc=sasldap,dc=com" -w 'SAS@ldapAdm1n' "$dn"
  done
```

---

# Riepilogo rapido

## Migrazione custom tra ambienti
```bash
# ambiente sorgente già popolato
./bin/export.sh

# nuovo ambiente già bootstrapato
./bin/import.sh ./export-no-root.ldif add
```

## Gestione incrementale
```bash
./bin/generate.sh
./bin/apply.sh
```
