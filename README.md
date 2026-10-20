# Landing zone Scaleway : hub and spoke avec firewall central

Socle réseau d'une organisation Scaleway, écrit en Terraform. Un projet central (la DSI) héberge deux firewalls OPNsense en haute disponibilité, la sortie Internet, le VPN et Interlink. Chaque département a son propre projet, créé et détruit à la demande.

**Garantie.** Tout flux qui sort d'un département, ou qui y entre depuis l'extérieur, passe par le firewall central. Seule exception : le contournement Interlink optionnel (`hybrid_bypass`). Ce qu'un département expose lui-même (Load Balancer, IP publique) n'est pas couvert : voir « Exposition directe » dans les limites.

Un seul module racine, un seul state, un seul fichier de configuration : `terraform.tfvars`.

```text
main.tf, variables.tf, outputs.tf   module racine
terraform.tfvars.example            modèle de configuration
modules/hub/                        DSI : VPC, firewalls, VPN, Interlink
modules/department/                 un département : projet, VPC, NACL, IAM
image/                              construction de l'image OPNsense
tests/, modules/*/tests/            tests hors ligne
docs/                               documentation
```

## Architecture

[![Architecture : projet DSI (VPC Egress, HA, Hub, Hybrid) et projets départements (VPC Pub et Private)](docs/architecture.png)](docs/architecture.png)

| Flux | Chemin | Contrôle |
|---|---|---|
| Département → Internet | Private → Pub → Hub → firewall → Public Gateway | firewall, NAT |
| Département A → département B | → Hub → firewall | bloqué par défaut ; NACL du département cible |
| Pub ↔ Private (même département) | peering direct | NACL |
| On-prem (VPN) ↔ département | VPN → Egress → Hub → firewall | firewall et `nacl_inbound` |
| On-prem (Interlink) ↔ Private | Interlink → Hybrid → Private | sans firewall (`hybrid_bypass`) |
| Internet → département | Load Balancer créé par le département | hors firewall |

Un seul firewall est actif. Il porte deux adresses virtuelles (VIP) dans l'IPAM, que le plugin `os-scw-lz` déplace vers l'autre nœud en cas de bascule.

Schémas des mécanismes : [peering](docs/notion-1-vpc-peering.png), [transitivité](docs/notion-2-transitivite.png), [ingress rules](docs/notion-3-ingress-rules.png), [NACL](docs/notion-4-nacl.png), [flux asymétriques](docs/notion-5-flux-asymetriques.png).

## Prérequis

**Outils.**

| Outil | Version minimale | Pourquoi |
|---|---|---|
| Terraform | 1.10 | `required_version = ">= 1.10"` |
| Provider `scaleway/scaleway` | 2.86 (`~> 2.86`) | installé par `terraform init` |
| Providers `hashicorp/random` (`~> 3.6`), `hashicorp/time` (`~> 0.12`) | idem | installés par `terraform init` |
| CLI `scw` | récente | doit être sur la machine qui lance Terraform : elle redémarre les firewalls après l'ajout de leurs cartes réseau et déplace ou libère les VIP à la destruction |
| `ssh` | | accès aux firewalls par le bastion |

**Droits Scaleway.**

- Une clé API d'**organisation** : elle crée des projets, applications, politiques et clés IAM, et gère VPC, Instances, Block Storage, IPAM, Public Gateways et VPN. Une clé d'administrateur convient.
- Un bucket Object Storage **privé et versionné** pour le state. Le state contient des secrets : réservez-le aux opérateurs.
- Les zones `fr-par-1` et `fr-par-2` pour les firewalls (`fr-par-3` n'a pas de Public Gateway).

**Image OPNsense.** Aucune image n'est publiée : construisez la vôtre avec `image/build.sh`, un snapshot par zone ([docs/IMAGE.md](docs/IMAGE.md#construire-limage)).

**Variables d'environnement.** Ne les versionnez jamais.

```bash
export SCW_ACCESS_KEY=<clé> SCW_SECRET_KEY=<secret> SCW_DEFAULT_ORGANIZATION_ID=<id-organisation>
export AWS_ACCESS_KEY_ID=$SCW_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SCW_SECRET_KEY   # accès au bucket du state
export STATE_BUCKET=<bucket-du-state>
```

La région (`fr-par`) est écrite dans `main.tf` ; c'est celle du bucket.

## Déploiement

Toutes les commandes se lancent depuis la racine du dépôt.

1. Construire l'image, un snapshot par zone (variables : [docs/IMAGE.md](docs/IMAGE.md#construire-limage)) :

   ```bash
   BUILD_SERVER=<zone>/<uuid> BUILD_SSH=root@<hôte-de-build> ZONES="fr-par-1 fr-par-2" BUCKET=<bucket> image/build.sh
   ```

2. Créer la configuration :

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   Renseignez au minimum `admin_cidrs` (votre IP publique en `/32`), `admin_ssh_public_keys`, les deux `snapshot_id` de `firewall.nodes` et vos `departments`. Toutes les options : [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

3. Initialiser, relire le plan, appliquer :

   ```bash
   terraform init -backend-config="bucket=$STATE_BUCKET"
   terraform plan
   terraform apply
   ```

4. Récupérer les accès d'administration et le mot de passe root (absent si vous fournissez `firewall.root_password_hash`) :

   ```bash
   terraform output -json access
   terraform output -raw fw_root_password
   ```

   Les firewalls redémarrent une fois pour appliquer leur configuration : tant que ce n'est pas fini, le SSH répond `stdio forwarding failed`. Attendez quelques minutes.

5. Vérifier : `terraform output departments` (adresses, projet et groupe IAM de chaque département) et `scw vpc vpc-connector list region=fr-par` (tous les connecteurs doivent être `peered`).

**Tests hors ligne** (aucun appel à Scaleway) :

```bash
terraform init -backend=false && terraform test
terraform -chdir=modules/hub init -backend=false && terraform -chdir=modules/hub test
terraform -chdir=modules/department init -backend=false && terraform -chdir=modules/department test
```

## Exploitation

Après chaque modification de `terraform.tfvars` : `terraform plan`, relecture, puis `terraform apply`.

**Ajouter un département.** Ajoutez une entrée dans `departments` avec un `index` unique (0-1023), puis `terraform apply`. Le plan ne doit montrer que les ressources du nouveau département. Ne changez jamais l'`index` d'un département existant.

```hcl
departments = {
  genomic   = { index = 1 }
  marketing = { index = 2 }
}
```

Dans la même entrée : `nacl_inbound` ouvre un flux entrant, `hybrid_bypass = true` relie le département à Interlink (demande `interlink`).

**Retirer un département.** Le département vide d'abord son projet (instances, LB, volumes, bases, buckets). Supprimez ensuite son entrée et lancez `terraform apply`. Gardez son `index` réservé tant que le projet n'est pas détruit.

**Changer la politique du firewall.** Modifiez `policy` (format : [docs/CONFIGURATION.md](docs/CONFIGURATION.md#policy)), puis `terraform apply`. Les firewalls la relisent en moins d'une minute, sans redémarrage. Appliquez la politique seule, sans autre changement de plateforme en attente. Un réglage fait dans le WebUI est écrasé au prochain changement.

**Reconstruire un firewall.** Un changement de plateforme (interfaces, CARP, passerelles, syslog) ou la rotation d'un secret demande de reconstruire le nœud. Reconstruisez d'abord le BACKUP, un nœud par `apply` :

```bash
ssh -J bastion@<ip-pgw>:61000 root@<ip-egress-du-nœud> 'ifconfig vtnet1 | grep carp'   # MASTER ou BACKUP
terraform apply -replace='module.hub.terraform_data.fw_generation["fw1"]'               # ou "fw2"
```

Gardez le préfixe `module.hub.`. Pour monter de version l'image, changez le `snapshot_id` d'un seul nœud par `apply`. Reconstruire le maître provoque une bascule : faites-le en fenêtre de maintenance.

**Faire tourner la clé API du hook.** Un nœud lit la clé une seule fois, à sa création.

```bash
terraform apply -replace='module.hub.scaleway_iam_api_key.fw_failover'
```

Reconstruisez ensuite fw2, puis fw1 (commande ci-dessus). Si une bascule survient entre les deux, déplacez les VIP à la main avec la ligne du nœud maître :

```bash
terraform output -json failover_commands
```

**Détruire.**

```bash
terraform destroy
```

Les ressources des départements (instances, LB, volumes, bases, buckets) doivent être supprimées avant. Si l'erreur `resource is still in use` apparaît, supprimez les security groups « Default » créés par Scaleway dans le projet du département, puis relancez :

```bash
scw instance security-group list zone=fr-par-1 project-id=<id-projet-département>
scw instance security-group delete <id> zone=fr-par-1
```

Faites de même dans `fr-par-2` si des VM y ont tourné. Récupérez les `project_id` avec `terraform output departments` avant la destruction.

## Dépannage

| Symptôme | Cause | Action |
|---|---|---|
| `stdio forwarding failed` en SSH vers un firewall | il démarre encore | attendre quelques minutes |
| `Connection timed out during banner exchange` vers une VM | port fermé par la NACL du département | ajouter une règle `nacl_inbound`, puis `apply` |
| Plus de trafic via le hub ou vers Internet après une bascule | VIP restées sur l'ancien maître | `terraform output -json failover_commands`, lancer la ligne du maître |
| Le journal du firewall (`grep scwlz /var/log/system/latest.log`) indique `rebuild this node` | changement de plateforme en attente ; le nœud ignore aussi la politique | reconstruire le nœud, le BACKUP d'abord |
| Le plan refuse `policy` | alias inconnu, description en double ou contenant `<`, `>`, `&`, port sans protocole | corriger `policy` |
| Le plan refuse les CIDR | chevauchement entre `cidrs`, `dept_supernet` et les CIDR on-prem | corriger les valeurs |
| `hybrid_bypass needs interlink to be set` | `hybrid_bypass = true` sans `interlink` | définir `interlink` ou repasser à `false` |
| `each department needs a unique index` | deux départements ont le même `index` | donner un `index` libre (jamais à un département déjà déployé) |
| `-replace` n'affiche aucun changement | adresse sans préfixe `module.hub.` | utiliser `module.hub.terraform_data.fw_generation["fw1"]` |
| `resource project with ID ... is not found` à la création d'un département | projet neuf pas encore connu de l'API VPC | relancer `terraform apply` |
| `resource is still in use` à la destruction | security group « Default » dans le projet du département | voir « Détruire » |

## Limites connues

- **Produits sans peering.** Redis, MongoDB, Kafka, OpenSearch et ClickHouse ne suivent pas le routage VPC : ils ne sont joignables que depuis leur Private Network.
- **Exposition directe.** Les chemins Internet créés par un département ne passent pas par le firewall : IP publique d'instance (`InstancesFullAccess`), Load Balancer, nœuds Kapsule avec IP publique. Le contrôle passe par IAM et par un inventaire des projets de département (`scw instance ip list project-id=<projet>`, `scw lb list project-id=<projet>`). Retirer `InstancesFullAccess`, `LoadBalancersFullAccess` ou `KubernetesFullAccess` de `iam_permission_sets` ferme ces voies.
- **Secrets dans le state.** Le state contient le hash root, le mot de passe CARP et la clé API du hook : protégez le bucket. Avant le second démarrage, ces secrets sont lisibles dans les métadonnées de l'instance.
- **Clé du hook.** La clé `IPAMFullAccess` qui déplace les VIP est limitée au projet DSI et aux IP des Public Gateways. Ces IP sont aussi la sortie Internet des départements : une clé qui fuite reste utilisable depuis n'importe quelle VM de département.
- **Sloppy state.** Les règles de transit et la règle `[OUT]` sont en *sloppy state* : pf ne vérifie plus les numéros de séquence TCP.
- **NACL.** Les retours sont ouverts en TCP et UDP sur 32768-65535 depuis toute source : un service qui écoute sur ces ports est joignable de l'extérieur du département (le firewall filtre ce qui vient du Hub, pas le bypass Interlink). Pas de NACL ni de routes IPv6.
- **Sessions.** Elles survivent à une bascule de firewall, jamais à la perte d'une Public Gateway (l'IP publique change).
- **Nouveaux départements.** Les VM déjà démarrées reçoivent les nouvelles routes par DHCP en jusqu'à 1 h.
- **Quota de peering.** 512 connecteurs par organisation : 127 départements sans bypass, 85 avec.
- **Un seul state.** Un `plan` regarde la DSI et tous les départements, et un `apply` verrouille le tout. Relisez chaque plan.
- **Journaux.** Ils restent locaux sauf si vous renseignez `firewall.syslog`.

## Documentation

- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) : toutes les options.
- [docs/IMAGE.md](docs/IMAGE.md) : l'image OPNsense et le plugin.

## Licence

Apache License 2.0 : voir [LICENSE](LICENSE).
