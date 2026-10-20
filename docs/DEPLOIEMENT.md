# Déployer et exploiter la landing zone

Ce guide part de zéro. Comptez environ 45 minutes, dont 15 minutes d'attente (création et démarrage des firewalls). Les options de configuration sont dans [CONFIGURATION.md](CONFIGURATION.md). Les termes techniques sont définis dans le glossaire du [README](../README.md).

Le dépôt est un seul module racine, avec un seul state. Toutes les commandes se lancent depuis la racine du dépôt. Tout se règle dans un seul fichier, `terraform.tfvars`.

> Ce guide a été suivi pas à pas en conditions réelles (voir « État de validation » dans le [README](../README.md#état-de-validation)). Relisez tout de même chaque `plan` avant l'`apply`.

## 1. Prérequis

**Outils.** Terraform 1.10 ou plus, la CLI `scw` (récente) et `ssh`. La CLI `scw` doit être présente sur la machine qui lance Terraform : elle redémarre les firewalls après l'ajout de leurs cartes réseau au premier démarrage, et détruit les VIP à la destruction (hook de destruction).

```bash
terraform version | head -1; scw version | head -1
```

**Accès Scaleway.**

- Une clé API d'**organisation**. Elle doit pouvoir créer des projets, des applications, politiques et clés IAM, et gérer VPC, Instances, Block Storage, IPAM, Public Gateways et VPN. Une clé d'administrateur de l'organisation convient. Les connecteurs de peering du Hub sont créés dans le projet DSI depuis chaque département, d'où le besoin d'une clé d'organisation.
- Un bucket Object Storage **privé et versionné** pour le state (le versioning permet de revenir à un state antérieur). Le state est un secret : il contient le hash root des firewalls et la clé API du hook. Réservez le bucket aux opérateurs de la DSI.

```bash
scw object bucket update <bucket> enable-versioning=true region=fr-par
```

- Des quotas suffisants. Le quota de connecteurs de peering est de 512 par organisation. Un département en consomme 4 (6 avec `hybrid_bypass`) et la DSI 2 : 127 départements au plus sans bypass, 85 si tous l'activent. Au-delà, demandez une hausse à Scaleway.
- Des zones fr-par-1 et fr-par-2 pour les firewalls : fr-par-3 n'a pas de Public Gateway.

**Variables d'environnement.** Les secrets ne vont jamais dans git.

```bash
export SCW_ACCESS_KEY=<clé> SCW_SECRET_KEY=<secret> SCW_DEFAULT_ORGANIZATION_ID=<id-organisation>
export AWS_ACCESS_KEY_ID=$SCW_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SCW_SECRET_KEY
export STATE_BUCKET=<bucket-du-state>
```

La région (`fr-par`) et la zone par défaut (`fr-par-1`) sont écrites dans le `main.tf` ; la région doit être celle du bucket et des zones des firewalls.

**Clé SSH d'administration.** Elle sert à se connecter aux firewalls par le bastion. Terraform, lui, ne se connecte jamais aux firewalls.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lz-admin -C lz-admin
```

Notez aussi votre IP publique : seule elle pourra joindre les bastions SSH.

```bash
curl -4 -s https://ifconfig.me; echo
```

## 2. Construire l'image golden

Aucune image n'est publiée : vous la construisez vous-même avec `image/build.sh` (prérequis, variables et durée dans [IMAGE.md](IMAGE.md#construire-limage)). Le script crée un snapshot par zone et affiche leur identifiant.

```bash
BUILD_SERVER=fr-par-2/<uuid-hôte-de-build> BUILD_SSH=root@<ip-hôte-de-build> \
ZONES="fr-par-1 fr-par-2" BUCKET=<bucket> PLUGIN_VERSION=1.0.8 \
image/build.sh
```

Notez l'identifiant du snapshot de chaque zone (`fr-par-1/<uuid>`, `fr-par-2/<uuid>`) : ils vont dans `firewall.nodes`.

## 3. Renseigner la configuration

Copiez le modèle en `terraform.tfvars` (ce fichier n'est jamais versionné) :

```bash
cp terraform.tfvars.example terraform.tfvars
```

Éditez-le : `admin_cidrs` (votre IP en `/32`), `admin_ssh_public_keys` (contenu de `~/.ssh/lz-admin.pub`), les deux `snapshot_id` de `firewall.nodes`, puis vos départements dans `departments`, en remplaçant l'exemple `genomic`. Ajoutez `vpn`, `interlink` et `policy` si besoin. Toutes les options sont décrites dans [CONFIGURATION.md](CONFIGURATION.md).

Vérifiez le formatage et la syntaxe :

```bash
terraform fmt -recursive -check
terraform init -backend=false -input=false >/dev/null && terraform validate
```

Les tests hors ligne (aucun appel à Scaleway) :

```bash
terraform test
terraform -chdir=modules/hub init -backend=false >/dev/null && terraform -chdir=modules/hub test
terraform -chdir=modules/department init -backend=false >/dev/null && terraform -chdir=modules/department test
```

## 4. Déployer

Initialisez avec le backend S3, prévisualisez (rien n'est créé), puis appliquez (environ 2 minutes) :

```bash
terraform init -backend-config="bucket=$STATE_BUCKET"
```

```bash
terraform plan
```

```bash
terraform apply
```

Le premier `apply` crée la DSI et tous les départements déclarés. L'avertissement `Multiple variable sources detected` est sans conséquence : les identifiants existent à la fois dans le profil `scw` et dans l'environnement.

Rien n'est poussé en SSH. Chaque firewall lit sa clé, ses secrets et sa configuration dans ses métadonnées au premier démarrage, puis efface ses secrets des métadonnées. L'apply crée aussi l'application IAM `<name>-fw-failover` et sa clé.

Récupérez les accès d'administration (commande SSH et tunnel WebUI, par nœud) et le mot de passe root si vous n'avez pas fourni `firewall.root_password_hash` :

```bash
terraform output -json access
```

```bash
terraform output -raw fw_root_password
```

## 5. Vérifier les firewalls

Au premier démarrage, chaque firewall lit sa configuration puis redémarre pour l'appliquer. **Attendez 4 à 5 minutes**, parfois jusqu'à 10 pour le bastion de la seconde zone. Avant cela, SSH répond `stdio forwarding failed` : c'est normal.

Les exemples ci-dessous utilisent le bastion de fw1 (`bastion@<ip-pgw>:<port>`, donné par la sortie `access`) et l'adresse egress par défaut de fw1 (`10.0.4.11`, fw2 : `10.0.4.12`).

Le journal du plugin confirme chaque étape :

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@10.0.4.11 'grep scwlz /var/log/system/latest.log'
```

Lignes à retrouver, parmi d'autres :

```console
... scwlz ... secrets stored, removed from the metadata
... scwlz ... failover settings updated
... scwlz ... configuration f4111cfa... stored, rebooting to apply it
... scwlz-vip ... alias 10.0.4.10 added on vtnet3
```

La dernière ligne n'apparaît que sur le maître : il porte la VIP egress.

Routes et rôle CARP :

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@10.0.4.11 'netstat -rn -f inet | grep -E "^default|^10.64.0|^169.254.169.254"; ifconfig vtnet1 | grep carp'
```

Le maître est le premier nœud élu au démarrage, fw1 ou fw2 : sans préemption, il le reste. Sortie attendue sur le maître, ici fw1 (sur l'autre nœud, `BACKUP`) :

```console
default            10.0.4.2           UGS          vtnet3
10.64.0.0/10       169.254.169.254    UGS          vtnet1
169.254.169.254    link#2             UHS          vtnet1
	carp: MASTER vhid 10 advbase 1 advskew 0
```

- `default ... 10.0.4.2` : la sortie Internet passe par la Public Gateway A.
- `10.64.0.0/10 ... vtnet1` : tous les départements sont joignables par la patte hub.
- Avec un VPN, une route par CIDR on-prem apparaît aussi, via `169.254.169.254`.
- Les VIP de données `172.16.0.10` (hub) et `10.0.4.10` (egress) sont rattachées au maître (ici `dsi-hub-fw1`) :

```bash
scw ipam ip list region=fr-par -o template='{{ .Address }} {{ .Resource.Name }}' 2>/dev/null | grep -E '^(172.16.0.10|10.0.4.10)/'
```

```console
10.0.4.10/24 dsi-hub-fw1
172.16.0.10/24 dsi-hub-fw1
```

## 6. Vérifier les départements

Adresses attribuées, projet et groupe IAM de chaque département :

```bash
terraform output departments
```

Vérifiez que tous les peerings sont `peered` :

```bash
scw vpc vpc-connector list region=fr-par -o json | python3 -c "import sys,json;[print(c['name'].ljust(34),c['status']) for c in json.load(sys.stdin)]"
```

Tests de fonctionnement, depuis une VM d'un département (accès par le bastion puis le firewall maître, avec une règle `nacl_inbound` sur le port 22 depuis `172.16.0.0/24`). Les clés de `admin_ssh_public_keys` ne sont pas déposées dans les projets des départements, et l'agent Scaleway réécrit `/root/.ssh/authorized_keys` d'après les clés du projet : passez la clé dans un second fichier par cloud-init (`test-vm.yaml`) :

```yaml
#cloud-config
write_files:
  - path: /etc/ssh/sshd_config.d/10-lz.conf
    content: "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys_lz\n"
  - path: /root/.ssh/authorized_keys_lz
    permissions: "0600"
    content: "<contenu de ~/.ssh/lz-admin.pub>\n"
runcmd:
  - systemctl restart ssh
```

VM sans IP publique, branchée sur le Private Network `private` du département (identifiants donnés par `terraform output departments`, sans le préfixe `fr-par/` pour la carte réseau) :

```bash
scw instance server create zone=fr-par-1 type=DEV1-S image=ubuntu_noble ip=none name=test-vm project-id=<project_id> cloud-init=@test-vm.yaml
```

```bash
scw instance private-nic create zone=fr-par-1 server-id=<id-de-la-vm> private-network-id=<uuid-du-private-network>
```

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000,root@<ip-egress-du-maître> root@<ip-de-la-vm>
```


| Test | Commande | Attendu |
|---|---|---|
| Sortie Internet | `curl -4 -s https://ifconfig.me` | IP publique de la PGW A |
| Chemin | `tracepath -n 1.1.1.1` | quelques sauts sans réponse (routeurs VPC), puis l'IP hub du maître (`172.16.0.11` pour fw1, `.12` pour fw2) et `10.0.4.2` |
| Inter-département | `curl -m 5 http://<ip-autre-département>:8080/` | échec (bloqué par le firewall ; ouvrez le port dans la `nacl_inbound` de la cible pour que la NACL ne bloque pas avant) |
| VPN | sur le routeur on-prem : `ipsec status`, `vtysh -c 'show bgp summary'` | 2 tunnels, 2 sessions BGP |

Un blocage inter-département est visible dans `/var/log/filter/latest.log` du firewall (lignes contenant `,block,`).

Les départements créent eux-mêmes leurs Load Balancers et Edge Services dans leur projet (ce n'est pas géré ici). Un département qui veut Edge Services souscrit lui-même son abonnement.

## 7. Réglages VPN côté on-prem

Si vous avez activé `vpn`, transmettez la sortie `vpn` (IP des deux passerelles, adresses BGP) à l'équipe réseau on-prem. Les clés pré-partagées sont dans Secret Manager (`psk_secret_id`).

```bash
terraform output vpn
```

L'on-prem doit monter **les deux tunnels** (un par zone). Scaleway n'expose aucun timer BGP, BFD ou DPD : la vitesse de bascule se règle sur la passerelle on-prem.

| Réglage | Valeur | Effet |
|---|---|---|
| BGP keepalive / hold, sur les deux sessions (`169.254.100.2` et `.6` par défaut) | 10 s / 30 s | Le hold retenu est le plus petit des deux côtés : la perte d'un tunnel est détectée en 30 s au plus, contre 162 s par défaut. |
| IKEv2 DPD (détection de pair mort) | 10 s, action *restart* | Le tunnel IPsec est relancé dès que la passerelle Scaleway revient. |

Vérification : sur un routeur FRR, `show bgp neighbors` doit afficher un hold time de 30 s. Coupez un tunnel et chronométrez la bascule.

## 8. Exploitation courante

### Modifier la politique du firewall

Éditez `policy` dans `terraform.tfvars` ([format](CONFIGURATION.md#policy)), puis :

```bash
terraform apply
```

Les deux nœuds relisent leurs métadonnées chaque minute et appliquent la politique à chaud : en moins d'une minute, sans redémarrage ni bascule. Les sessions déjà établies continuent jusqu'à leur expiration. Contrôle :

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@10.0.4.12 'grep scwlz /var/log/system/latest.log | tail -1'
```

```console
... scwlz ... policy fc2ad80a... applied (filter and routes reloaded)
```

**Ne mélangez pas politique et plateforme.** Tant qu'un changement de plateforme attend sa reconstruction (journal `rebuild this node`), le nœud n'applique plus aucun changement, politique comprise. Appliquez la politique seule, et reconstruisez sans tarder après un changement de plateforme.

Un changement fait dans le WebUI est remplacé au prochain changement de politique : le WebUI sert au diagnostic, pas à la gestion. Une erreur dans `policy` (alias inconnu, description en double...) fait échouer le plan, sans rien appliquer. Supprimer `policy` de `terraform.tfvars` retire toute la politique du client au prochain apply.

### Ajouter ou retirer un département

Ajouter : une entrée dans `departments` avec un `index` libre, puis `terraform apply`. Le plan ne montre que les ressources du nouveau département ; relisez-le. L'apply dure environ 1 min 30 : un projet neuf n'est connu de l'API VPC qu'au bout d'une minute environ, et le module attend 90 s avant d'y créer les VPC. Les firewalls ne sont jamais modifiés (le hub ignore les changements sur eux).

```hcl
departments = {
  genomic   = { index = 1 }
  marketing = { index = 2 }
}
```

Une ouverture NACL (`nacl_inbound`) ou le bypass Interlink (`hybrid_bypass`) se règlent dans la même entrée, puis par un `apply`. Les membres du groupe IAM `dept-<nom>` sont gérés hors Terraform (console ou SCIM).

Retirer : le département vide d'abord son projet (instances, LB, volumes, bases, buckets). Supprimez ensuite son entrée de `departments` et faites `terraform apply`. Le plan ne doit détruire que les ressources de ce département. Gardez l'index réservé tant que le projet n'est pas entièrement détruit. En cas d'erreur `resource is still in use`, voir « Tout détruire ».

### Reconstruire un nœud

Un nœud reconstruit a un serveur **et** un volume neufs. Il relit ses secrets, sa configuration et la politique dans ses métadonnées, et revient en BACKUP. L'autre nœud garde le trafic.

```bash
terraform apply -replace='module.hub.terraform_data.fw_generation["fw1"]'
```

Gardez le préfixe `module.hub.` : sans lui, Terraform ne trouve pas la ressource et n'affiche aucun changement, sans erreur.

C'est aussi la façon d'appliquer un changement de **plateforme** (interfaces, CARP, passerelles, système, syslog) ou de faire tourner un secret. Reconstruisez d'abord le BACKUP. Reconstruire le maître provoque une bascule : 19 à 30 s de pause TCP, sessions conservées. Faites-le en fenêtre de maintenance. Rôle d'un nœud :

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@10.0.4.12 'ifconfig vtnet1 | grep carp'
```

### Monter de version (image golden, type d'instance)

**Un nœud par apply.** Changer le `snapshot_id` des deux nœuds dans un même apply remplace les deux serveurs en parallèle : plus de firewall pendant la reconstruction. Le type d'instance (`firewall.instance_type`) n'est pas modifié sur un serveur existant : il ne s'applique qu'à un nœud reconstruit. Rejetez à la relecture tout plan qui annonce la destruction des deux `scaleway_instance_server.fw`.

1. Repérez le BACKUP (`ifconfig vtnet1 | grep carp`).
2. Changez le `snapshot_id` du BACKUP seul dans `terraform.tfvars`. Pour un nouveau type d'instance, changez `instance_type` puis utilisez `-replace` sur `module.hub.terraform_data.fw_generation["<backup>"]`.
3. `terraform plan` : un seul `scaleway_instance_server.fw` doit être remplacé. Puis `terraform apply`.
4. Vérifiez que le nœud revient BACKUP, que `pfctl -sr | grep quick | sha256` donne la même valeur sur les deux nœuds (sans `grep quick`, les règles antispoof, propres à chaque nœud, diffèrent), et que `grep scwlz /var/log/system/latest.log` est sans erreur.
5. Faites de même pour l'autre nœud (le maître : une bascule, en fenêtre de maintenance).

### Bascule manuelle

Une bascule normale ne demande rien (voir le README). Si le journal `scwlz-vip` du maître montre un échec persistant, déplacez les VIP à la main. Lancez la ligne du nœud maître :

```bash
terraform output -json failover_commands
```

Pour rendre la main à fw1 après une bascule, passez fw2 en mode maintenance CARP (WebUI, *Interfaces > Virtual IPs > Status*) puis sortez-le.

### Rotation de la clé du hook

Un nœud lit la clé une seule fois, à sa création.

1. Remplacez la clé : `terraform apply -replace='module.hub.scaleway_iam_api_key.fw_failover'`. L'ancienne est supprimée : les nœuds en service ne peuvent plus déplacer les VIP.
2. Sans attendre, reconstruisez fw2, puis fw1 (section « Reconstruire un nœud »), en attendant que chacun revienne BACKUP.
3. Si une bascule survient entre les deux, utilisez `failover_commands` (ci-dessus).

### Révoquer un administrateur

Retirez sa clé de `admin_ssh_public_keys` et appliquez. Les bastions (Public Gateways) la perdent aussitôt, et les firewalls ne sont joignables qu'à travers eux. Les firewalls gardent la clé dans leur compte root jusqu'à leur reconstruction : reconstruisez-les l'un après l'autre pour la purger.

### Lire les journaux et les alertes

Journal du plugin (une ligne par action ; sens de chaque ligne dans [IMAGE.md](IMAGE.md#journal-du-plugin)) :

```bash
ssh -i ~/.ssh/lz-admin -J bastion@<ip-pgw>:61000 root@10.0.4.11 'grep scwlz /var/log/system/latest.log | tail'
```

Journal du filtre : `/var/log/filter/latest.log`. Pour les centraliser et créer des alertes (CARP, passerelle *down*, `scwlz-vip` en erreur, `rebuild this node`), envoyez-les vers votre collecteur avec `firewall.syslog` (changement de plateforme : reconstruction des nœuds).

IP de sortie à déclarer dans les allow-lists des partenaires (les deux) :

```bash
terraform output egress_public_ips
```

## 9. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `stdio forwarding failed` en SSH vers un firewall | il démarre encore | attendre 4 à 5 minutes après la création (jusqu'à 10 pour le second bastion) |
| `Connection timed out during banner exchange` vers une VM | port non ouvert par la NACL du département | ajouter une règle `nacl_inbound` à l'entrée du département dans `terraform.tfvars`, puis `apply` |
| Plus de trafic via le hub ou vers Internet après une bascule | VIP restées sur l'ancien maître (journal `scwlz-vip` en erreur) | lancer `failover_commands` du nœud maître |
| Un firewall ne répond jamais, la console série montre « Start PXE over IPv4 » | image non amorçable en UEFI | utiliser l'image golden (GPT avec partition EFI) |
| Un firewall reconstruit ne répond jamais | disque réutilisé d'un ancien serveur | reconstruire par `fw_generation` |
| Journal `rebuild this node`, politique non appliquée | le changement touche la plateforme ; tant que le nœud n'est pas reconstruit, il ignore aussi les changements de politique | reconstruire le nœud (le BACKUP d'abord) |
| Journal `split brain: peer alive and holding ...` | les deux nœuds sont maîtres, mais le pair répond sur le réseau sync (patte hub coupée ou partition) | vérifier la patte hub du nœud concerné ; les VIP sont rendues dans la minute après le retour à la normale |
| Un nœud perd toutes les élections CARP (`sysctl net.inet.carp.demotion` à 240, `syncok: 0`) | synchronisation pfsync initiale bloquée | le cron la relance en 2 minutes (journal `pfsync bulk transfer stuck: re-armed`) |
| Un firewall n'a ni Internet ni API après son boot | route par défaut restée sur le hub | le cron la corrige en moins d'une minute ; sinon `configctl interface routes configure` |
| Le plan refuse `policy` | alias inconnu, description en double ou contenant `<`, `>`, `&`, port sans protocole tcp ou udp | corriger `policy` ([CONFIGURATION.md](CONFIGURATION.md#policy)) |
| Le plan refuse les CIDR ou les numéros d'hôte | chevauchement entre `cidrs`, `dept_supernet` et les CIDR on-prem, ou numéros d'hôte en collision | corriger les valeurs ([CONFIGURATION.md](CONFIGURATION.md)) |
| Le plan échoue : `hybrid_bypass needs interlink to be set` | un département a `hybrid_bypass = true` sans `interlink` | définir `interlink`, ou repasser `hybrid_bypass` à `false` |
| Le plan échoue : `each department needs a unique index` | deux départements ont le même `index` | donner un `index` libre à l'un des deux (jamais à un département déjà déployé) |
| `-replace` n'affiche aucun changement | adresse sans préfixe `module.hub.` | utiliser `module.hub.terraform_data.fw_generation["fw1"]` |
| Création d'un département : `resource project with ID ... is not found` | projet neuf pas encore connu de l'API VPC (l'attente de 90 s n'a pas suffi) | relancer `terraform apply` |
| Destruction d'un département : `resource is still in use` | security group « Default » créé par Scaleway dans le projet | voir « Tout détruire » |

## 10. Tout détruire

Les ressources des départements (instances, LB, volumes, bases, buckets) doivent être supprimées avant. Un seul state : une seule commande détruit les départements puis la DSI.

```bash
terraform destroy
```

La destruction d'un département peut échouer :

```console
Error: scaleway-sdk-go: precondition failed: resource is still in use, all resources are not deleted
```

L'erreur ne nomme pas la ressource : `terraform state list` montre ce qui reste, en pratique les projets des départements (tout le reste est détruit). Cause : Scaleway crée un security group « Default » dans le projet du département quand on y lance une VM. Listez ceux du projet, supprimez-les (uniquement ceux du projet du département), puis relancez la destruction :

```bash
scw instance security-group list zone=fr-par-1 project-id=<id-projet-département>
```

```bash
scw instance security-group delete <id> zone=fr-par-1
```

Faites de même dans l'autre zone si des VM y ont tourné.

Il arrive aussi que la destruction réussisse mais laisse ce security group orphelin, sans projet. Notez l'identifiant du projet de chaque département avant de le détruire (`terraform output departments`, champ `project_id`) et vérifiez ensuite que la liste ci-dessus est vide ; sinon, supprimez ce qui reste.
