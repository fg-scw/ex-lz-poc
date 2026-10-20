# Landing zone Scaleway : hub and spoke avec firewall central en haute disponibilité

Cette landing zone est le socle réseau d'une organisation Scaleway, écrit en Terraform. Elle s'adresse aux équipes qui veulent donner à chaque département (une unité métier) son propre projet Scaleway, tout en gardant le contrôle des flux au même endroit.

Un projet central, la **DSI**, héberge deux firewalls OPNsense en haute disponibilité (un par zone), la sortie Internet, le VPN et Interlink. Chaque **département** a son propre projet, créé et détruit à la demande.

**Garantie.** Tout flux qui sort d'un département, ou qui y entre depuis l'extérieur, passe par le firewall central. Seule exception : le contournement Interlink optionnel (`hybrid_bypass`), qui relie un département à l'on-prem sans inspection. Ce qu'un département expose lui-même (Load Balancer, IP publique) n'est pas couvert : voir « Exposition directe » dans les limites.

Le tout se déploie avec un seul module racine, un seul state et un seul fichier de configuration (`terraform.tfvars`). Ajouter un département, c'est ajouter une entrée dans ce fichier, sans toucher aux firewalls. Relisez chaque `plan` avant l'`apply`.

## Architecture

[![Architecture déployée : un projet DSI (VPC Egress avec deux Public Gateways, deux passerelles VPN et la VIP egress ; VPC HA ; VPC Hub avec la VIP hub, prochain saut des ingress rules, portée par le firewall OPNsense maître ; VPC Hybrid avec Interlink), et N projets départements dept-<nom> (VPC Pub transitif, VPC Private, NACL, peering de contournement Interlink optionnel). Tout flux sortant d'un département passe par le firewall ; seul Interlink vers Private le contourne. La landing zone ne déploie ni Load Balancer ni Edge Services : un département crée ses propres LB dans son VPC Pub.](docs/architecture.png)](docs/architecture.png)

Cliquez sur le schéma pour l'ouvrir en grand.

## Les briques

- **Projet DSI.** Il contient quatre VPC (réseaux privés isolés) :
  - *Egress* : deux Public Gateways (une par zone), deux passerelles VPN, et la patte « egress » des firewalls ;
  - *HA* : un réseau réservé à la synchronisation entre les deux firewalls ;
  - *Hub* : la patte « hub » des firewalls. Les ingress rules y envoient tout le trafic des départements vers le firewall actif ;
  - *Hybrid* : Interlink, le lien privé vers l'on-prem, sans inspection.
- **Firewalls OPNsense (fw1 en fr-par-1, fw2 en fr-par-2).** Un seul est actif (maître). Ils démarrent depuis l'**image golden** et lisent leur configuration dans les métadonnées de l'instance.
- **Projets départements.** Chaque département a un VPC *Pub* (transitif) et un VPC *Private* (applications). Des NACL imposées par la DSI filtrent les deux. Son groupe IAM n'a aucun droit sur le réseau.
- **Public Gateways.** Elles font sortir le trafic vers Internet (NAT) et servent de bastion SSH vers les firewalls.
- **VPN site à site (optionnel).** Un tunnel IPsec par zone, avec BGP. Le trafic on-prem est inspecté par le firewall.
- **Interlink (optionnel).** Les départements qui l'activent (`hybrid_bypass`) joignent l'on-prem sans passer par le firewall.
- **VIP de données (IPAM).** Deux adresses réservées dans l'IPAM de Scaleway portent le trafic. Elles suivent le firewall maître.

La landing zone ne déploie ni Load Balancer ni Edge Services, ni relais de journaux : un département crée ses propres LB et Edge Services (son groupe IAM a `LoadBalancersFullAccess` et `EdgeServicesFullAccess`) et souscrit lui-même son abonnement Edge Services. Les journaux des firewalls partent vers un collecteur par `firewall.syslog`.

| Flux | Chemin | Contrôle |
|---|---|---|
| Département → Internet | Private → Pub → Hub → firewall → Public Gateway | firewall, NAT sur la VIP egress |
| Département A → département B | → Hub → firewall | bloqué par défaut ; NACL du département cible |
| Pub ↔ Private (même département) | peering direct | NACL : Pub → Private ouvert |
| On-prem (VPN) ↔ département | VPN → Egress → Hub → firewall | firewall et `nacl_inbound` |
| On-prem (Interlink) ↔ département Private | Interlink → Hybrid → Private | **sans firewall** ; NACL ouverte aux CIDR on-prem |
| Internet → département | LB que le département crée lui-même dans son VPC Pub | **hors firewall** : voir « Exposition directe » |

Le firewall ignore les départements : tous tiennent dans un seul bloc d'adresses (`dept_supernet`, `10.64.0.0/10`). Une ingress rule, un alias (`DEPT_NETS`) et une route statique suffisent, quel que soit le nombre de départements. L'`index` d'un département dans `departments` (`terraform.tfvars`) fixe ses adresses (1024 départements possibles, sans chevauchement).

### Notions réseau

Cinq schémas courts expliquent les mécanismes de cette segmentation, avec l'exemple de `dept-genomic` :

1. [VPC peering : un connecteur de chaque côté](docs/notion-1-vpc-peering.png)
2. [Transitivité : Private atteint le Hub à travers Pub](docs/notion-2-transitivite.png)
3. [Ingress rules : tout ce qui entre dans le Hub va au firewall](docs/notion-3-ingress-rules.png)
4. [NACL : un filtre sans état sur chaque VPC de département](docs/notion-4-nacl.png)
5. [Flux asymétriques : l'aller et le retour par le même chemin](docs/notion-5-flux-asymetriques.png)

## Comment marche la bascule

1. CARP, le protocole d'élection d'OPNsense, désigne le maître. Il ne porte aucun trafic, car Scaleway n'accepte que l'adresse MAC réelle d'une carte.
2. Le trafic passe par deux VIP de l'IPAM, rattachées à la MAC réelle du maître : la VIP hub (prochain saut des ingress rules) et la VIP egress (source du NAT).
3. Quand un nœud devient maître depuis 3 s, son plugin `os-scw-lz` déplace les deux VIP vers ses cartes par l'API IPAM, avec une clé dédiée.
4. Un cron relance cette logique chaque minute et corrige les écarts. Un nœud qui revient reste BACKUP (pas de préemption).
5. Mesuré (voir « État de validation ») : CARP désigne le nouveau maître en 13 à 14 s, les VIP le rejoignent en 16 à 17 s, et la coupure ICMP est de quelques secondes (5,6 à 6,2 s, mesurées avant l'ajout de la patte egress à la règle `[OUT]`). Les sessions TCP établies, entre départements comme vers Internet, survivent dans les deux sens grâce à la règle flottante `[OUT]` : elle passe les flux sortants des pattes hub et egress en *sloppy state*, avant la règle de sortie par défaut d'OPNsense. Une session ne survit jamais à la perte d'une Public Gateway (l'IP publique change), et une application doit savoir rouvrir une connexion.

Détails : [docs/IMAGE.md](docs/IMAGE.md).

## Image golden et configuration des firewalls

Les firewalls démarrent depuis une **image golden** : OPNsense officiel plus le plugin `os-scw-lz`, sans aucun secret. Aucune image n'est publiée : construisez la vôtre avec `image/build.sh` ([docs/IMAGE.md](docs/IMAGE.md)), puis renseignez le snapshot de chaque zone dans `firewall.nodes`.

La configuration des firewalls vient de `terraform.tfvars` : le module `hub` l'écrit dans les métadonnées de chaque instance. Le plugin `os-scw-lz` les relit chaque minute. La politique du client (`policy`) est appliquée à chaud, en moins d'une minute. Tout autre changement (plateforme, secrets, syslog) demande de reconstruire le nœud ; la configuration complète est lue au premier démarrage.

## Glossaire

| Terme | Sens |
|---|---|
| DSI | équipe et projet Scaleway qui possèdent le réseau central (le « hub », nommé `dsi-hub` par défaut) |
| Département | une unité métier : un projet Scaleway, deux VPC (Pub et Private), un groupe IAM |
| VPC | réseau privé isolé de Scaleway |
| Private Network | sous-réseau d'un VPC, où se branchent les cartes réseau |
| Public Gateway (PGW) | passerelle NAT vers Internet, avec un bastion SSH |
| IPAM | service Scaleway qui gère les adresses IP privées |
| VIP | adresse virtuelle qui suit le firewall maître |
| CARP | protocole d'OPNsense qui élit le maître parmi les firewalls |
| pfsync | synchronisation des sessions entre les deux firewalls |
| Image golden | image OPNsense identique pour tous les clients, sans secret |
| Métadonnées d'instance | données que Scaleway fournit à un serveur (`user_data`) |
| Module racine, state unique | la racine du dépôt est le seul module déployé ; son state (clé `landing-zone/terraform.tfstate`) contient la DSI et tous les départements |
| NACL | liste de règles réseau sans état, sur un VPC |

## Démarrage rapide

Prérequis, variables d'environnement et vérifications : [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md).

```bash
cp terraform.tfvars.example terraform.tfvars   # puis adaptez-le
terraform init -backend-config="bucket=<bucket>"
terraform apply
```

Les tests hors ligne (aucun appel à Scaleway) :

```bash
terraform init -backend=false && terraform test
terraform -chdir=modules/hub init -backend=false && terraform -chdir=modules/hub test
terraform -chdir=modules/department init -backend=false && terraform -chdir=modules/department test
```

Le contenu de chaque fichier du dépôt est décrit dans [ARBORESCENCE.md](ARBORESCENCE.md).

## État de validation

Déploiement testé sur Scaleway (fr-par-1 et fr-par-2) avec Terraform 1.15.5, le provider Scaleway 2.87.0, l'image golden 1.0.8 et deux départements. Les durées sont des mesures, pas des garanties.

- **Déploiement.** 89 ressources en un seul `apply` (1 min 45). Les firewalls sont configurés au démarrage et redémarrés 3 min après la fin de l'`apply`. Les 10 connecteurs de peering sont `peered`.
- **Flux.** Sortie Internet par la Public Gateway A, via le firewall maître. Flux entre départements bloqué par le firewall (visible dans son journal). Une exception `policy` s'ouvre 43 s après l'`apply` et se referme en 12 s.
- **Départements.** Ajout et retrait sans toucher aux firewalls (18 à 19 ressources, toutes dans le département). Le module attend 90 s après la création d'un projet, car l'API VPC ne le connaît qu'au bout d'environ 70 s.
- **Bascule.** Dans les deux sens, avec la règle `[OUT]` : CARP en 14 s, VIP déplacées en 16 à 17 s. Les sessions entre départements et vers Internet survivent, sans `state-mismatch` (la session Internet s'est arrêtée 18 s dans un sens). Sans `[OUT]`, une session Internet était perdue dans un sens. Coupure ICMP : 5,6 à 6,2 s, mesurée avant l'ajout de la patte egress à `[OUT]`.
- **Destruction.** Tout est détruit, rien ne reste, une fois supprimés les security groups « Default » créés par les VM.
- **VPN.** Testé sur une version antérieure des mêmes modules, avec un site on-prem simulé : 2 tunnels IPsec, 2 sessions BGP, bascule de tunnel en 162 s avec les réglages par défaut.

**Non validé en réel :**
- **Interlink et `hybrid_bypass`** : aucune liaison Interlink n'était disponible.
- **VPN avec le module racine unique** : le test ci-dessus date d'une version antérieure.
- **Load Balancer et Edge Services** : ils ne font pas partie de la landing zone ; Edge Services demande un domaine dont on contrôle le DNS.
- **Régions autres que `fr-par`.**

## Limites connues

- **Produits sans peering.** Redis, MongoDB, Kafka, OpenSearch et ClickHouse ne suivent pas le routage VPC : ils ne sont joignables que depuis leur Private Network.
- **Exposition directe.** Les chemins Internet créés par un département ne passent pas par le firewall : une IP publique attachée à une instance (`InstancesFullAccess`), un Load Balancer qu'il crée lui-même, des nœuds Kapsule avec IP publique. Le contrôle est IAM et un inventaire par projet de département : `scw instance ip list project-id=<projet du département>` et `scw lb list project-id=<projet du département>` ne doivent montrer que ce que la DSI a validé. Retirer `InstancesFullAccess`, `LoadBalancersFullAccess` ou `KubernetesFullAccess` de `iam_permission_sets` ferme ces voies.
- **Secrets.** Le state contient le hash root, le mot de passe CARP et la clé API du hook : protégez le bucket. Avant le second boot, ces secrets sont lisibles dans les métadonnées (environ une minute).
- **Capacité de sortie.** Toute la sortie passe par un firewall (`POP2-2C-8G` par défaut, 0,4 Gbps) et une Public Gateway (`VPC-GW-S` par défaut, 0,1 Gbps) : le plus lent des deux fixe le débit. Le type de PGW se change à chaud (descendre de type a coupé la sortie 20 min lors d'un essai : à faire en fenêtre de maintenance), celui du firewall impose une reconstruction. Une `VPC-GW-L` apporte de la bande passante, pas plus de paquets par seconde qu'une `VPC-GW-M`.
- **Sessions.** Elles survivent à une bascule de firewall grâce à la règle `[OUT]`, jamais à celle d'une Public Gateway (l'IP publique change).
- **Bascule par script.** Le déplacement des VIP dépend du plugin et d'une clé `IPAMFullAccess`, limitée au projet DSI et aux IP des Public Gateways. Ces IP ne désignent pas les seuls firewalls : la sortie Internet des départements passe par les mêmes Public Gateways. Une clé fuitée (state, disque d'un firewall) reste donc utilisable depuis n'importe quelle VM de département, pour déplacer ou libérer les VIP de données.
- **Sloppy state.** Les règles de transit et la règle `[OUT]` sont en *sloppy state* : pf ne vérifie plus les numéros de séquence TCP.
- **VPN.** Sans réglage sur l'on-prem, BGP met 162 s à basculer d'un tunnel à l'autre (30 s au plus avec les réglages recommandés).
- **NACL.** Les retours sont ouverts en TCP et UDP sur 32768-65535 depuis toute source : un service qui écoute sur ces ports est joignable de l'extérieur du département (filtré par le firewall s'il vient du Hub, pas par le bypass Interlink). Pas de NACL ni de routes IPv6.
- **Journaux.** Ils restent locaux sauf si vous branchez `firewall.syslog`.
- **Nouveaux départements.** Les VM déjà démarrées reçoivent les nouvelles routes par DHCP en jusqu'à 1 h.
- **Quota de peering.** 512 connecteurs par organisation : 127 départements sans bypass, 85 avec.
- **Un seul state.** Un `plan` regarde la DSI et tous les départements, et un `apply` verrouille le tout. Les firewalls ne sont pas touchés par l'ajout ou le retrait d'un département (le module hub ne dépend pas de la liste des départements), mais relisez le plan.

## Documents

- [ARBORESCENCE.md](ARBORESCENCE.md) : le rôle de chaque fichier du dépôt.
- [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md) : déployer pas à pas, exploiter, dépanner, détruire.
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) : toutes les options.
- [docs/IMAGE.md](docs/IMAGE.md) : l'image golden et le plugin.
