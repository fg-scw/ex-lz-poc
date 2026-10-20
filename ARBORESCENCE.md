# Arborescence du dépôt

Ce document décrit chaque fichier du dépôt : son rôle, les ressources Terraform qu'il crée et la logique qu'il porte. Pour déployer, voir [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md). Pour le vocabulaire, voir le glossaire du [README](README.md).

## Vue d'ensemble

```
.
├── main.tf                          module racine : backend, providers, appel du hub et des départements
├── variables.tf                     entrées du module racine (terraform.tfvars)
├── outputs.tf                       sorties : access, departments, vpn, interlink...
├── terraform.tfvars.example         modèle de terraform.tfvars
├── .terraform.lock.hcl              versions verrouillées des providers
├── .gitignore                       fichiers exclus (secrets, state, caches)
├── README.md                        point d'entrée
├── ARBORESCENCE.md                  ce document
├── tests/
│   └── landing-zone.tftest.hcl      test du module racine
├── modules/
│   ├── hub/                         projet DSI : réseau central, firewalls HA, VPN, Interlink
│   │   ├── network.tf
│   │   ├── firewall.tf
│   │   ├── failover.tf
│   │   ├── policy.tf
│   │   ├── hybrid.tf
│   │   ├── opnsense-config.xml.tftpl
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf
│   │   └── tests/hub.tftest.hcl
│   └── department/                  un département : projet, VPC Pub et Private, NACL, IAM
│       ├── main.tf
│       ├── nacl.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── tests/department.tftest.hcl
├── image/                           image golden OPNsense et plugin os-scw-lz
│   ├── build.sh
│   ├── bake.sh
│   ├── bootstrap-config.xml
│   ├── tests/test-vip.sh
│   └── plugin/
│       ├── +MANIFEST
│       └── usr/local/
│           ├── etc/cron.d/scwlz
│           ├── etc/rc.syshook.d/carp/90-scwlz-vip
│           ├── etc/rc.syshook.d/start/99-scwlz-sync
│           ├── opnsense/scripts/scwlz/sync.sh
│           ├── opnsense/scripts/scwlz/vip.sh
│           └── opnsense/service/conf/actions.d/actions_scwlz.conf
└── docs/
    ├── DEPLOIEMENT.md
    ├── CONFIGURATION.md
    ├── IMAGE.md
    ├── architecture.png
    └── notion-1-vpc-peering.png ... notion-5-flux-asymetriques.png
```

Le flux de données du code, de haut en bas : `terraform.tfvars` alimente le module racine. Celui-ci appelle `modules/hub` une fois, puis `modules/department` une fois par département avec la sortie `department_contract` du hub. Le hub écrit la configuration des firewalls dans les métadonnées des instances, et le plugin `os-scw-lz` de l'image golden la lit.

## Module racine

Le module racine ne crée aucune ressource lui-même. Il assemble le hub et les départements dans un seul state.

| Fichier | Rôle | Ressources / logique |
|---|---|---|
| `main.tf` | Point d'entrée Terraform | Bloc `terraform` : version minimale 1.10, providers `scaleway`, `random`, `time`, backend S3 sur Object Storage (clé `landing-zone/terraform.tfstate`, verrou natif `use_lockfile`, bucket donné à l'`init`). Provider `scaleway` (région `fr-par`, zone `fr-par-1`). `module "hub"` (transmet les variables) et `module "department"` en `for_each` sur `var.departments` (nom, `index`, `hybrid_bypass`, `nacl_inbound`, contrat du hub, `iam_permission_sets`). |
| `variables.tf` | Entrées | Obligatoires : `admin_cidrs`, `admin_ssh_public_keys`, `firewall`. Optionnelles : `vpn`, `interlink`, `policy`, `departments`, `iam_permission_sets`, et les réglages avancés (`name`, `project_id`, `tags`, `cidrs`, `dept_supernet`, `egress`). Les valeurs transmises au hub sont typées `any` (le hub les type et les vérifie ; `null` = défaut du module). `departments` est typée ici, avec deux validations : `index` unique, et `hybrid_bypass` seulement si `interlink` est défini. |
| `outputs.tf` | Sorties | Reprend celles du hub (`project_id`, `firewall`, `failover_commands`, `egress_public_ips`, `access`, `vpn`, `fw_root_password`, `interlink`). `interlink` et `fw_root_password` sont sensibles. Ajoute `departments` : par département, `project_id`, `cidrs`, `private_network_ids`, `iam_group_id`, `hybrid_bypass`. |
| `terraform.tfvars.example` | Modèle de configuration | À copier en `terraform.tfvars` (jamais versionné). Montre `admin_cidrs`, `admin_ssh_public_keys`, `firewall.nodes` (un snapshot par zone), `vpn`, `interlink`, `policy` et `departments` en exemple, avec les blocs facultatifs commentés. |
| `.terraform.lock.hcl` | Verrou des providers | Versions et empreintes de `scaleway`, `random` et `time`. |
| `.gitignore` | Exclusions | `terraform.tfvars`, `*.auto.tfvars`, `backend.hcl`, `.env`, `.terraform/`, les fichiers de state, `crash.log`, les verrous des modules (`modules/*/.terraform.lock.hcl`) et `.DS_Store`. |

## Module `modules/hub` (projet DSI)

Le hub crée le projet central : quatre VPC, deux Public Gateways, la paire de firewalls OPNsense, le failover des VIP, et en option le VPN site à site et Interlink. Il publie `department_contract`, que chaque département consomme.

| Fichier | Rôle | Ressources / logique |
|---|---|---|
| `network.tf` | Réseau du hub | **Plan d'adressage** : `department_pools` découpe `dept_supernet` (Pub : un quart ; Private : la moitié haute). `local.vpcs` : quatre VPC (`egress`, `ha`, `hub`, `hybrid`).<br>`scaleway_account_project` (seulement si `project_id` est nul), `scaleway_vpc` et `scaleway_vpc_private_network` (un par VPC), `scaleway_iam_ssh_key` (une par clé admin).<br>Par zone de firewall : `scaleway_vpc_public_gateway_ip`, `scaleway_vpc_public_gateway` (NAT et bastion SSH limité à `admin_cidrs`), `scaleway_ipam_ip` (adresse fixe de la gateway), `scaleway_vpc_gateway_network` (masquerade, route par défaut).<br>Peering Egress et Hub : deux `scaleway_vpc_connector`, `scaleway_vpc_route` (supernet des départements vers le hub ; réseau egress et CIDR VPN vers l'egress).<br>`scaleway_vpc_ingress_rule` : tout paquet qui entre dans le Hub depuis le supernet des départements, l'egress ou les CIDR VPN est envoyé à la VIP hub (le firewall actif). |
| `firewall.tf` | Paire de firewalls | **Adresses** : IP des nœuds par réseau, VIP d'élection CARP (`vhid` 10), VIP de données `hub` et `egress`. **Configuration** : rendu du modèle XML pour chaque nœud (`fw_config`), hash de la partie plateforme (`fw_platform_hash`, le XML sans les sections `filter`, `nat`, `staticroutes` et `Firewall`), liste `internal_nets` jamais envoyée sur Internet, secrets `KEY='value'` (`fw_secrets`).<br>`random_password` (root et CARP), `scaleway_ipam_ip` (`fw` : une IP par nœud et par réseau ; `fw_vip` : VIP d'élection ; `data_vip` : VIP de données, créées sur fw1 puis déplacées par le plugin, avec un provisioner de destruction qui les ramène sur la MAC du state), `terraform_data.fw_generation` (reconstruire un nœud = remplacer serveur et volume ensemble), `scaleway_block_volume` (volume neuf par nœud depuis le snapshot golden), `scaleway_instance_server` (métadonnées `opnsense_config`, `opnsense_platform`, `opnsense_secrets`), trois `scaleway_instance_private_nic` (hub, sync, egress, dans cet ordre), `terraform_data.fw_first_boot` (un redémarrage par `scw` une fois les cartes attachées). |
| `failover.tf` | Accès du hook de bascule | `scaleway_iam_application`, `scaleway_iam_policy` (`IPAMFullAccess`, limitée au projet DSI et aux IP publiques des Public Gateways), `scaleway_iam_api_key` (remise au nœud par `opnsense_secrets`). `scaleway_instance_user_data.scwlz` : réglages de bascule de chaque nœud (vhid, interfaces, identifiants IPAM des VIP et MAC du nœud, IP sync, MAC et nom du pair), lus par `vip.sh`. |
| `policy.tf` | Politique en données | Aucune ressource. Rend les règles, alias et règles NAT en entrées pour le modèle XML. Règles de la landing zone : `[EW]` bloque département vers département, `[DSI]` laisse passer l'egress DSI vers les départements, `[VPN]` (si VPN) laisse passer l'on-prem dans les deux sens, `[EGRESS]` laisse sortir les départements vers Internet (non journalisée). Les règles du client passent avant. UUID déterministes (`uuidv5`) : un nouveau rendu ne change que ce que le client a changé. |
| `hybrid.tf` | VPN et Interlink | VPN (si `vpn` est défini), une passerelle par zone : `scaleway_s2s_vpn_gateway`, `data.scaleway_ipam_ip` (IP publique de la passerelle), `scaleway_s2s_vpn_customer_gateway`, `scaleway_s2s_vpn_routing_policy`, `scaleway_s2s_vpn_connection` (BGP, chiffrements IKEv2 et ESP).<br>Interlink (si `interlink` est défini) : `scaleway_interlink_routing_policy` et `scaleway_interlink_link` sur le VPC Hybrid. |
| `opnsense-config.xml.tftpl` | Modèle de `config.xml` OPNsense | Rendu sans secret (jetons `@@KEY@@` remplis sur le nœud). Sections : système (SSH sur l'egress seulement, WebUI sur le réseau sync), interfaces statiques, VIP CARP, pfsync, passerelles et surveillance dpinger, NAT sortant (SNAT vers la VIP egress), règles flottantes `[MGMT]`, `[HA]`, `[OUT]` (*sloppy state*, sortie des pattes hub et egress), règles de la politique, routes statiques (supernet des départements et on-prem par le routeur VPC), alias, syslog distant. |
| `variables.tf` | Entrées et validations | `name`, `project_id`, `tags`, `cidrs`, `dept_supernet`, `admin_cidrs`, `admin_ssh_public_keys`, `firewall`, `egress`, `vpn`, `interlink`, `policy`. Valeurs par défaut et contrôles : chevauchements de CIDR (entre réseaux de la DSI, avec le supernet, avec l'on-prem), numéros d'hôte en collision, exactement une source de disque par nœud, caractères XML refusés dans les descriptions, alias inconnu dans `policy`, transport et port du syslog. |
| `outputs.tf` | Sorties | `department_contract` (VPC Hub et Hybrid, pools Pub et Private, CIDR Interlink), `firewall` (VIP, nœuds, hash de plateforme), `failover_commands` (déplacement manuel des VIP), `egress_public_ips`, `access` (SSH et tunnel WebUI par le bastion), `vpn`, `interlink`, `fw_root_password`, `project_id`. |
| `versions.tf` | Providers | Contraintes de version de Terraform et des providers du module. |
| `tests/hub.tftest.hcl` | Tests hors ligne | Provider simulé (aucun appel API). Vérifie notamment le plan d'adressage et les ingress rules, la configuration d'amorçage (dont la règle `[OUT]`), le hook de bascule, que la politique ne touche pas à la plateforme, le hash root fourni par le client, le syslog, les CIDR internes, les chiffrements VPN et les refus de valeurs invalides. |

## Module `modules/department` (un département)

Un appel du module crée un département : son projet, deux VPC, les peerings vers le hub, les routes, les NACL et le groupe IAM. L'`index` fixe ses adresses.

| Fichier | Rôle | Ressources / logique |
|---|---|---|
| `main.tf` | Projet, réseau et IAM | **Adresses** : un `/22` Pub et un `/21` Private sont pris dans les pools du hub à la position `index`.<br>`scaleway_account_project`, `time_sleep` (90 s : un projet neuf n'est connu de l'API VPC qu'au bout d'environ 70 s), deux `scaleway_vpc` (Pub avec `enable_transitivity`, Private) et deux `scaleway_vpc_private_network`.<br>Six `scaleway_vpc_connector` : Pub et Hub (un de chaque côté), Pub et Private (un de chaque côté), et, si `hybrid_bypass`, Private et Hybrid (un de chaque côté).<br>`scaleway_vpc_route` : défaut du Pub vers le hub, Pub vers Private, défaut du Private vers Pub, retour du Hub vers Pub et Private, et, avec le bypass, Private vers les CIDR on-prem par Interlink et retour du Hybrid.<br>`scaleway_iam_group` (membres gérés hors Terraform) et `scaleway_iam_policy` (`iam_permission_sets`, aucun droit sur le réseau). |
| `nacl.tf` | NACL imposées | Génère les règles des deux VPC : sortie ouverte, Pub vers Private ouvert, retours sans état sur 32768-65535 (TCP, UDP) et ICMP, CIDR on-prem du bypass, puis les règles `nacl_inbound` du département. Une plage de ports `0` devient `0-65535`, car l'API lit `0-0` comme « port 0 ».<br>`scaleway_vpc_acl` (un par VPC, politique par défaut `drop`, IPv4 seulement). |
| `variables.tf` | Entrées | `name`, `index` (0 à 1023), `hybrid_bypass`, `nacl_inbound` (liste de règles `to`, `source`, `protocol`, `port`, `port_end`), `hub` (contrat du hub), `iam_permission_sets`. Validations de l'`index`, du bypass sans Interlink et des règles NACL. |
| `outputs.tf` | Sorties | `project_id`, `cidrs` (Pub et Private), `private_network_ids`, `iam_group_id`, `hybrid_bypass` (vrai seulement si Interlink est défini). |
| `versions.tf` | Providers | Contraintes de version de Terraform et des providers du module (`scaleway`, `time`). |
| `tests/department.tftest.hcl` | Tests hors ligne | Provider simulé. Position 0 sans bypass, position 5 avec bypass, bypass sans Interlink refusé, `index` hors plage refusé, règle NACL invalide refusée. |

## Tests du module racine

| Fichier | Rôle | Ressources / logique |
|---|---|---|
| `tests/landing-zone.tftest.hcl` | Test du module racine | Provider simulé. Trois cas : départements et bypass avec Interlink, `index` en double refusé, `hybrid_bypass` sans `interlink` refusé. Les modules ont leurs propres tests (voir plus haut). |

## Image golden et plugin (`image/`)

Ce dossier construit l'image OPNsense sans secret et contient le plugin `os-scw-lz` qui lit les métadonnées et déplace les VIP. Voir [docs/IMAGE.md](docs/IMAGE.md).

| Fichier | Rôle | Ressources / logique |
|---|---|---|
| `image/build.sh` | Orchestrateur de la construction (poste de l'opérateur, CLI `scw` et SSH) | Variables : `BUILD_SERVER`, `BUILD_SSH`, `BUILD_SSH_OPTS`, `OPNSENSE_VERSION`, `NANO_SHA256`, `PLUGIN_VERSION`, `IMAGE_NAME`, `ZONES`, `BUCKET`, `PROJECT_ID`, `DISK_GB`. Crée un volume SBS, l'attache à l'hôte de build, copie `bake.sh`, le fichier de configuration d'amorçage et le plugin, lance `bake.sh`, détache le volume, crée un snapshot, l'exporte en qcow2 dans Object Storage puis l'importe dans chaque zone. Affiche un snapshot par zone et nettoie le volume en sortie. |
| `image/bake.sh` | Fabrication du disque (sur l'hôte de build FreeBSD) | Vérifie la somme SHA-256 de l'image nano. Construit le paquet `os-scw-lz` (`pkg create`). Découpe le disque en GPT (partition EFI, amorce BIOS, racine UFS) et y copie le système nano, car l'image nano seule ne démarre pas en UEFI. Installe `bootstrap-config.xml` et le paquet. Supprime l'état propre à un hôte (clés SSH, entropie). Le contrôle final fait échouer la construction s'il trouve une clé, un hash de mot de passe ou une clé API. L'image n'est jamais démarrée. |
| `image/bootstrap-config.xml` | Configuration de départ de l'image | Générique et sans secret : root verrouillé, aucune clé, SSH désactivé, menu console sous mot de passe, seul `vtnet0` assigné. La vraie configuration arrive par les métadonnées. |
| `image/tests/test-vip.sh` | Test hors réseau de `vip.sh` | Charge les fonctions de `vip.sh` avec des commandes simulées (`ping`, `logger`) et vérifie la garde contre le double maître et la restitution des VIP au pair. Placé hors de `plugin/`, car `bake.sh` empaquette tout ce dossier. |
| `image/plugin/+MANIFEST` | Métadonnées du paquet `os-scw-lz` | Nom, version (`%%VERSION%%`, remplacée par `bake.sh`), description, mainteneur, adresse du dépôt. |
| `image/plugin/usr/local/opnsense/scripts/scwlz/sync.sh` | Lecture de la configuration (au démarrage et chaque minute) | Lit `user_data` sur le routeur VPC (`169.254.169.254`, port source aléatoire inférieur à 1024). Range `opnsense_secrets` dans `/conf/scwlz/secrets.env` puis l'efface des métadonnées. Met à jour les réglages `scwlz`. Remplace les jetons `@@KEY@@` de `opnsense_config`. Sur un nœud neuf : écrit la configuration puis **redémarre** pour l'appliquer. Sur un nœud en service : applique la politique à chaud (migrations de modèles, rechargement du filtre et des routes) et **refuse** un changement de plateforme (journal `rebuild this node`). |
| `image/plugin/usr/local/opnsense/scripts/scwlz/vip.sh` | **Hook de bascule** des VIP de données | Appelé à chaque changement d'état CARP puis chaque minute. Quand le nœud est maître depuis 3 s, déplace les VIP de données vers ses cartes par l'API IPAM (nouvelles tentatives, clé du hook). Ajoute l'alias egress sur le maître (ARP gratuit) et le retire sur un BACKUP. Corrige la route par défaut restée sur le hub, relance pfsync bloqué, rend au pair une VIP qu'un BACKUP détiendrait, et évite le va-et-vient en cas de double maître (le pair doit répondre sur le réseau sync). |
| `image/plugin/usr/local/etc/cron.d/scwlz` | Planification | Chaque minute : `sync.sh cron` et `vip.sh reconcile`. |
| `image/plugin/usr/local/etc/rc.syshook.d/start/99-scwlz-sync` | Démarrage | Lance `sync.sh boot` à chaque boot. |
| `image/plugin/usr/local/etc/rc.syshook.d/carp/90-scwlz-vip` | Événement CARP | Passe l'événement (`vhid@interface`, état) à `vip.sh`. |
| `image/plugin/usr/local/opnsense/service/conf/actions.d/actions_scwlz.conf` | Actions `configctl` | Déclare les actions `sync` et `vip` pour les lancer à la main. |

## Documentation (`docs/`)

| Fichier | Rôle | Contenu |
|---|---|---|
| `docs/DEPLOIEMENT.md` | Guide de déploiement et d'exploitation | Prérequis, construction de l'image, configuration, `apply`, vérifications, réglages VPN on-prem, exploitation (politique, départements, reconstruction, montée de version, bascule manuelle, rotation de clé), dépannage, destruction. |
| `docs/CONFIGURATION.md` | Référence des options | Variables d'environnement, backend, exemple minimal, chaque option de `terraform.tfvars` (et si elle s'applique à chaud, par reconstruction ou sur l'infrastructure), options avancées. |
| `docs/IMAGE.md` | Image golden et plugin | Contenu de l'image, construction, contrat des métadonnées, secrets, journal du plugin, tests. |
| `docs/architecture.png` | Schéma d'architecture | Le hub (quatre VPC), les départements et les flux. |
| `docs/notion-1-vpc-peering.png` | Notion 1 | VPC peering : un connecteur de chaque côté. |
| `docs/notion-2-transitivite.png` | Notion 2 | Transitivité : Private atteint le Hub à travers Pub. |
| `docs/notion-3-ingress-rules.png` | Notion 3 | Ingress rules : tout ce qui entre dans le Hub va au firewall. |
| `docs/notion-4-nacl.png` | Notion 4 | NACL : un filtre sans état sur chaque VPC de département. |
| `docs/notion-5-flux-asymetriques.png` | Notion 5 | Flux asymétriques : l'aller et le retour par le même chemin. |
