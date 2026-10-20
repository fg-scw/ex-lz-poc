# Image golden OPNsense

Une seule image sert tous les déploiements : OPNsense officiel plus le plugin `os-scw-lz`, **sans donnée sensible**. Chaque déploiement y charge ses secrets au déploiement, par les métadonnées de l'instance. Personne ne se connecte en SSH pour configurer un firewall.

## Version

Aucune image n'est publiée : chaque déploiement construit la sienne avec `image/build.sh` (voir plus bas). Les versions de référence sont OPNsense 26.1 (nano) et le plugin `os-scw-lz` 1.0.8. Le script publie un snapshot par zone et, si `BUCKET` est donné, un qcow2 `releases/opnsense-26.1-scwlz-<version du plugin>.qcow2` dans ce bucket.

## Contenu

| Élément | Origine | Rôle |
|---|---|---|
| OPNsense 26.1 nano | image officielle `OPNsense-26.1-nano-amd64.img.bz2`, SHA-256 vérifié | système, recopié tel quel |
| Disque GPT | `bake.sh` | partition EFI (`loader.efi` de l'image), amorce BIOS, racine UFS : les instances Scaleway démarrent en UEFI, l'image nano seule ne démarre pas |
| `/conf/config.xml` | `image/bootstrap-config.xml` | configuration de départ verrouillée : root verrouillé, aucune clé, SSH désactivé, menu console sous mot de passe, seul `vtnet0` assigné |
| Paquet `os-scw-lz` | `image/plugin/` | lit secrets, configuration et réglages de bascule dans les métadonnées ; déplace les VIP de données |

Le contrôle final de `bake.sh` fait échouer la construction si l'image contient : des clés d'hôte SSH (`/etc/ssh`, `/conf/sshd`), une graine d'entropie, `/root/.ssh`, des sauvegardes de configuration, un `PRIVATE KEY`, une clé SSH publique, un hash de mot de passe ou une clé API. Seules exceptions : les configurations d'usine d'OPNsense (`/usr/local/etc/config.xml*`), utilisées par une réinitialisation d'usine depuis la console, elle-même verrouillée.

L'image n'est jamais démarrée pendant sa fabrication. Chaque instance génère ses clés d'hôte et son entropie à son premier démarrage.

## Construire l'image

Prérequis : CLI `scw` configurée, un bucket Object Storage dans la région, et un **hôte de build** joignable en SSH : une instance OPNsense 26.x du projet (par exemple un firewall d'une landing zone de test, ou une instance OPNsense dédiée) avec environ 4 Go libres dans `/var/tmp`.

```bash
BUILD_SERVER=fr-par-2/<uuid-hôte-de-build> \
BUILD_SSH=root@10.0.4.12 BUILD_SSH_OPTS="-J bastion@<ip-pgw>:61000" \
ZONES="fr-par-1 fr-par-2" BUCKET=<bucket> PLUGIN_VERSION=1.0.8 \
image/build.sh
```

| Variable | Défaut | Rôle |
|---|---|---|
| `BUILD_SERVER` | obligatoire | `<zone>/<uuid>` de l'hôte de build |
| `BUILD_SSH` | obligatoire | destination SSH de l'hôte de build |
| `BUILD_SSH_OPTS` | vide | options SSH (bastion) |
| `OPNSENSE_VERSION` | `26.1` | version d'OPNsense |
| `NANO_SHA256` | lu dans le fichier officiel de sommes | empreinte de l'image nano |
| `PLUGIN_VERSION` | `1.0.0` | version du paquet `os-scw-lz` |
| `IMAGE_NAME` | `opnsense-<version>-scwlz-<version du plugin>` | nom des snapshots et du qcow2 |
| `ZONES` | zone de l'hôte de build | zones de publication |
| `BUCKET` | aucun | bucket du qcow2 ; obligatoire si `ZONES` dépasse la zone de l'hôte de build |
| `PROJECT_ID` | projet `scw` par défaut | projet des snapshots |
| `DISK_GB` | `25` | taille du volume golden |

Le script crée un volume SBS, l'attache à l'hôte de build, y fabrique l'image (`bake.sh`), le détache, en fait un snapshot, l'exporte en qcow2 dans le bucket, puis l'importe dans chaque zone. Il affiche un snapshot par zone (`fr-par-1/<uuid>`, `fr-par-2/<uuid>`). Durée : environ 15 minutes.

## Utiliser l'image

Le snapshot de chaque zone se renseigne dans `firewall.nodes.<nœud>.snapshot_id` ([CONFIGURATION.md](CONFIGURATION.md)). Pour partager l'image avec un autre projet ou une autre organisation, exportez-la en qcow2 (le script le fait quand `BUCKET` est donné) et importez-la dans chaque zone cible :

```bash
scw block snapshot import-from-object-storage zone=fr-par-1 bucket=<bucket> key=releases/opnsense-26.1-scwlz-1.0.8.qcow2 name=opnsense-golden
```

Pour changer de version sur une DSI en service, suivez [Monter de version](DEPLOIEMENT.md#monter-de-version-image-golden-type-dinstance) : un nœud par apply.

## Contrat des métadonnées (`user_data`)

Terraform (`modules/hub`) écrit, par nœud :

| Clé | Contenu | Après lecture |
|---|---|---|
| `opnsense_secrets` | lignes `KEY='value'` : `ROOT_HASH`, `ADMIN_KEYS_B64`, `CARP_PASS`, `SCW_SECRET_KEY` | rangée dans `/conf/scwlz/secrets.env` (root seulement), puis **supprimée des métadonnées par le nœud** |
| `opnsense_config` | `config.xml` en base64, secrets remplacés par des jetons `@@KEY@@` | relue chaque minute |
| `opnsense_platform` | hash de la partie plateforme (interfaces, CARP, HA, passerelles, système) | comparé à chaque changement |
| `scwlz` | réglages de bascule : vhid, interfaces, IDs IPAM des VIP, MAC du nœud, IP sync, nom et MAC du pair | relue chaque minute |

Deux tâches tournent : `sync.sh` au démarrage puis chaque minute (cron), et `vip.sh` à chaque changement d'état CARP puis chaque minute. À chaque passage, `sync.sh` :

- applique un changement de **politique** (règles, NAT, alias, routes) à chaud : migrations de modèles d'OPNsense comme au démarrage, puis rechargement du filtre et des routes, sans redémarrage ni bascule ;
- refuse un changement de **plateforme** sur un nœud qui a déjà une configuration, même après un redémarrage, et l'écrit au journal (`rebuild this node`) ;
- applique tout sur un nœud neuf (pas encore de `config.hash`) : il stocke la configuration puis redémarre pour l'appliquer.

Les sessions établies avant un changement de politique continuent jusqu'à leur expiration ; les nouvelles suivent la nouvelle politique.

`vip.sh` déplace les deux VIP vers les cartes du nœud quand il est maître depuis 3 s, avec la clé API du hook. Il ajoute l'alias egress (adresse gratuitement annoncée en ARP), retire cet alias sur un BACKUP, corrige la route par défaut restée sur le hub, relance pfsync bloqué, et rend au pair une VIP qu'un BACKUP détiendrait encore. Une garde évite le va-et-vient en cas de double maître : un passage du cron ne reprend pas une VIP détenue par un pair qui répond encore sur le réseau sync.

## Secrets du client

- **Mot de passe root** : `firewall.root_password_hash` (bcrypt, `htpasswd -nbB root <mot de passe>`), pour qu'aucun mot de passe en clair n'existe. Sans lui, un mot de passe est généré (sortie `fw_root_password`).
- **Clés SSH admin** : `admin_ssh_public_keys`.
- **Clé API du hook** : générée par le module. Droit `IPAMFullAccess`, limitée au projet DSI et aux requêtes venant des IP publiques des Public Gateways.
- **Rotation** : un nœud ne lit ses secrets qu'une fois, à sa création. Changer un secret revient à reconstruire les nœuds l'un après l'autre ([DEPLOIEMENT.md](DEPLOIEMENT.md#rotation-de-la-clé-du-hook)). Le mot de passe CARP doit rester identique sur les deux nœuds : pour le changer, reconstruisez les deux en fenêtre de maintenance.

## Journal du plugin

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@<ip-fw> 'grep scwlz /var/log/system/latest.log | tail'
```

| Ligne | Sens |
|---|---|
| `secrets stored, removed from the metadata` | secrets lus puis effacés des métadonnées |
| `failover settings updated` | réglages `scwlz` mis à jour |
| `configuration <hash> stored, rebooting to apply it` | configuration complète enregistrée, appliquée par un redémarrage |
| `policy <hash> applied (filter and routes reloaded)` | politique appliquée à chaud |
| `platform change ...: rebuild this node to apply it` | changement de plateforme en attente d'une reconstruction |
| `configuration waits for its secrets` | la configuration est là, pas encore les secrets |
| `rejected configuration <hash>: not an OPNsense config` | configuration invalide, ignorée |
| `metadata unreachable` | métadonnées injoignables au démarrage |
| `alias 10.0.4.10 added on vtnet3` | ce nœud est maître et porte la VIP egress |
| `<id> -> <nœud> (<mac>) after <n> tries` | la VIP `<id>` a été déplacée vers ce nœud |
| `<id> -> <nœud> failed: HTTP <code> after <n> tries` | échec du déplacement : voir la bascule manuelle |
| `default route off vtnet3: routing re-evaluated` | route par défaut corrigée après le démarrage |
| `pfsync bulk transfer stuck: re-armed` | synchronisation d'états relancée |
| `<id> handed back to <pair> (<mac>): this node is BACKUP` | fin d'un double maître : le BACKUP rend une VIP |
| `split brain: peer alive and holding <id>, not moving it` | les deux nœuds sont maîtres, mais le pair répond sur le réseau sync : la VIP n'est pas reprise ; à investiguer (patte hub d'un nœud, partition) |

Les lignes de `vip.sh` portent le tag `scwlz-vip`, celles de `sync.sh` le tag `scwlz`.

## Tests du plugin

```bash
for f in image/plugin/usr/local/opnsense/scripts/scwlz/*.sh image/*.sh; do sh -n "$f"; done
```

```bash
sh image/tests/test-vip.sh
```

Le premier contrôle la syntaxe des scripts. Le second teste hors réseau la garde du double maître et la restitution des VIP. Les tests sont hors de `image/plugin/`, car `bake.sh` empaquette tout cet arbre.
