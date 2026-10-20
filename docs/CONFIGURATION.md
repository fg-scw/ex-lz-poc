# Configuration : toutes les options

Toute la configuration tient dans un seul fichier, `terraform.tfvars` (copie de `terraform.tfvars.example`, jamais versionnée). Les options courantes viennent d'abord. Les options avancées, que la plupart des déploiements laissent à leur valeur par défaut, sont regroupées à la fin ([Options avancées](#options-avancées)). Pour déployer, voir [DEPLOIEMENT.md](DEPLOIEMENT.md).

Les variables du module racine (`variables.tf`) sont typées `any` quand elles ne font que transmettre une valeur au module `hub` : c'est lui qui les type et les vérifie (`modules/hub/variables.tf`). Les valeurs par défaut viennent donc du code des modules. Une option sans défaut est obligatoire. `null` veut dire « valeur par défaut du module ».

**Quand une option s'applique.**

- *À chaud* : l'apply suffit. Les firewalls appliquent le changement en moins d'une minute, sans redémarrage.
- *Reconstruction* : l'apply ne change rien sur un nœud en service. Le nœud écrit `rebuild this node` dans son journal. Il faut le reconstruire, un nœud après l'autre ([DEPLOIEMENT.md](DEPLOIEMENT.md#reconstruire-un-nœud)).
- *Infra* : l'apply modifie des ressources Scaleway, sans toucher aux firewalls.

## Variables d'environnement et backend

Le `main.tf` déclare le backend S3 et le provider Scaleway : **un seul state**, clé `landing-zone/terraform.tfstate`, verrou natif `use_lockfile`. Le nom du bucket se donne à l'`init` : `terraform init -backend-config="bucket=$STATE_BUCKET"`.

| Variable | Défaut | Rôle |
|---|---|---|
| `SCW_ACCESS_KEY`, `SCW_SECRET_KEY` | obligatoire | clé API d'organisation, lue par le provider Scaleway |
| `SCW_DEFAULT_ORGANIZATION_ID` | obligatoire | organisation qui reçoit les projets |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | obligatoire | clés Object Storage du bucket du state (mêmes valeurs que `SCW_*` ici) |
| `STATE_BUCKET` | obligatoire | nom du bucket du state (pour `-backend-config`) |

La région (`fr-par`) et la zone par défaut (`fr-par-1`) sont écrites dans les blocs `provider` et `backend` du `main.tf`. Pour une autre région, changez-les ; elle doit être celle des zones des firewalls.

## Exemple minimal

```hcl
admin_cidrs           = ["203.0.113.10/32"]
admin_ssh_public_keys = ["ssh-ed25519 AAAA... admin@dsi"]

firewall = {
  nodes = {
    fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid du snapshot golden>" }
    fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid du snapshot golden>" }
  }
}

departments = {
  genomic = { index = 1 }
}
```

## Variables du module racine

| Variable | Type | Défaut | Effet | Application |
|---|---|---|---|---|
| `admin_cidrs` | liste de CIDR | obligatoire | IP publiques autorisées sur le bastion SSH des Public Gateways ; `0.0.0.0/0` est refusé | infra |
| `admin_ssh_public_keys` | liste | obligatoire | clés OpenSSH (ed25519, rsa, ecdsa) des bastions et du compte root des firewalls | bastions : infra ; firewalls : reconstruction |
| `firewall` | objet | obligatoire | l'OPNsense HA ; voir [`firewall`](#firewall) | reconstruction |
| `vpn` | objet | `null` | VPN site à site inspecté ; voir [`vpn`](#vpn) | infra ; `onprem_cidrs` à chaud |
| `interlink` | objet | `null` | Interlink sans inspection ; voir [`interlink`](#interlink) | infra ; `onprem_cidrs` à chaud |
| `policy` | objet | `{}` | politique du client ; voir [`policy`](#policy) | à chaud |
| `departments` | map d'objets | `{}` | les départements ; voir [`departments`](#departments) | infra |
| `iam_permission_sets` | liste | `null` | droits du groupe IAM de chaque département ; voir [Options avancées](#options-avancées) | infra |
| `name`, `project_id`, `tags`, `cidrs`, `dept_supernet`, `egress` | | `null` | surcharges avancées du hub ; voir [Options avancées](#options-avancées) | variable |

### `firewall`

Chaque nœud a une `zone` (fr-par-1 ou fr-par-2) et exactement un parmi `snapshot_id` (cas normal : `<zone>/<uuid>` du snapshot golden), `volume_id` (`<zone>/<uuid>`, volume SBS existant) ou `image` (image ou ID local à la zone). Les zones des nœuds fixent aussi celles des Public Gateways et des passerelles VPN.

| Champ | Défaut | Effet |
|---|---|---|
| `nodes` | obligatoire | exactement `fw1` et `fw2`, chacun avec `zone` et un parmi `snapshot_id`, `volume_id`, `image` |
| `instance_type` | `POP2-2C-8G` | taille des firewalls ; fixe le débit de sortie (`POP2-2C-8G` : 0,4 Gbps) |
| `root_password_hash` | `null` | hash bcrypt du mot de passe root (`htpasswd -nbB root <mot de passe>`) ; `null` génère un mot de passe (sortie `fw_root_password`) |
| `syslog` | `[]` | collecteurs syslog distants ; voir [Options avancées](#options-avancées) |
| `disk`, `hosts`, `system`, `gateway_monitors` | voir plus bas | réglages avancés |

Exemple avec mot de passe et syslog :

```hcl
firewall = {
  instance_type      = "POP2-2C-8G"
  root_password_hash = "$2y$10$..."
  syslog             = [{ host = "10.0.4.5", port = 514, transport = "udp" }]
  nodes = {
    fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid>" }
    fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid>" }
  }
}
```

### `vpn`

```hcl
vpn = {
  customer_gateway_ip = "198.51.100.1"
  customer_asn        = 65010
  onprem_cidrs        = ["192.168.100.0/24"]
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `customer_gateway_ip` | obligatoire | IP publique du routeur on-prem |
| `customer_asn` | obligatoire | numéro AS BGP de l'on-prem |
| `onprem_cidrs` | obligatoire | réseaux on-prem joignables par le VPN |
| `gateway_type` | `VGW-S` | taille des passerelles VPN |
| `ciphers` | IKE et ESP : `aes256`, `sha256`, `modp2048` | `ike` et `esp`, chacun avec `encryption`, `integrity`, `dh_group` |
| `bgp_links` | a : `169.254.100.1/30` (Scaleway), `.2/30` (on-prem) ; b : `169.254.100.5/30`, `.6/30` | liens BGP des deux tunnels |

Un tunnel IPsec avec BGP est créé par zone. Le trafic on-prem passe par le firewall. La sortie `vpn` donne les IP des passerelles et les clés pré-partagées (`psk_secret_id`).

### `interlink`

```hcl
interlink = {
  pop_id         = "fr-par/<uuid de la PoP>"
  bandwidth_mbps = 1000
  partner_id     = "fr-par/<uuid du partenaire>"
  onprem_cidrs   = ["10.10.0.0/16"]
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `pop_id`, `bandwidth_mbps`, `onprem_cidrs` | obligatoires | PoP, débit, réseaux on-prem |
| `partner_id` | `null` | lien hébergé |
| `connection_id` | `null` | lien en propre ; alors `peer_asn` et `vlan` |
| `peer_asn`, `vlan` | `null` | lien en propre seulement |

Exactement un parmi `partner_id` ou `connection_id`. Le lien est lié au VPC Hybrid. Seuls les VPC Private des départements avec `hybrid_bypass` l'atteignent, sans firewall. La clé d'appairage à donner au partenaire est dans la sortie `interlink` (sensible : `terraform output -json interlink`).

### `departments`

Une entrée par département, dont la clé est le nom (2 à 24 caractères : minuscules, chiffres et tirets, en commençant par une lettre). C'est la source unique du plan d'adressage et de la politique réseau imposée à chaque département. Ajouter une entrée crée son projet, ses VPC et ses NACL ; la retirer les détruit.

```hcl
departments = {
  genomic = {
    index         = 1
    hybrid_bypass = true
    nacl_inbound = [
      {
        to          = "private"
        source      = "10.0.4.0/24"
        port        = 8080
        description = "DSI load balancers to genomic backends"
      },
    ]
  }
  hr = { index = 2 }
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `index` | obligatoire | entier unique de 0 à 1023, **permanent**. Il fixe le Pub (/22 pris dans `10.64.0.0/12`) et le Private (/21 pris dans `10.96.0.0/11`). Ne le changez jamais pour un département en service ; gardez celui d'un département détruit réservé jusqu'à la suppression de son projet |
| `hybrid_bypass` | `false` | relie le VPC Private au VPC Hybrid (Interlink, sans firewall). **Exige `interlink`** : sans lui, le plan échoue. Coûte 2 connecteurs de peering de plus |
| `nacl_inbound` | `[]` | flux autorisés **vers** le département depuis l'extérieur (on-prem, DSI, autre département) |

Deux `index` identiques font échouer le plan. Les NACL du département refusent tout trafic entrant qui n'est pas déclaré. Un élément de `nacl_inbound` a les champs :

| Champ | Défaut | Valeurs |
|---|---|---|
| `to` | obligatoire | `pub` ou `private` |
| `source` | obligatoire | CIDR |
| `protocol` | `TCP` | `ANY`, `TCP`, `UDP`, `ICMP` |
| `port`, `port_end` | `0` (tous les ports), fin = `port` | numéro de port ou plage |
| `description` | `Inbound from <source>` | texte libre |

Ce que les NACL ouvrent toujours : tout le trafic sortant ; Pub vers Private dans le département ; les retours TCP et UDP sur les ports 32768-65535 ; ICMP ; l'entrée depuis l'on-prem Interlink si `hybrid_bypass`. Le trafic interne à un Private Network n'est jamais filtré.

Chaque département reçoit aussi un groupe IAM `dept-<nom>` (droits : voir `iam_permission_sets`). Ses ressources portent le préfixe `dept-<nom>` et le tag `department:<nom>`. Les CIDR, l'ID du projet et les Private Networks de chaque département sont dans la sortie `departments`.

**Load Balancers et Edge Services.** Ils ne sont plus gérés par la landing zone. Le groupe IAM du département a `LoadBalancersFullAccess` et `EdgeServicesFullAccess` : il crée ses LB dans son VPC Pub et souscrit lui-même son abonnement Edge Services. Ces chemins Internet ne passent pas par le firewall ([Limites connues](../README.md#limites-connues)).

### `policy`

Optionnel. Il étend la politique du firewall. Application *à chaud* en moins d'une minute. Une erreur fait échouer le plan, sans rien appliquer. Trois sections, toutes optionnelles :

```hcl
policy = {
  aliases = {
    DEPT_GENOMIC = ["10.96.8.0/21"]  # Private du département d'index 1
    DEPT_HR      = ["10.96.16.0/21"] # Private du département d'index 2
  }
  rules = [
    {
      description = "Genomic reaches HR over HTTPS"
      action      = "pass"
      source      = "DEPT_GENOMIC"
      destination = "DEPT_HR"
      protocol    = "tcp"
      port        = 443
    },
  ]
  nat_outbound = [
    { description = "Genomic SNAT to the Internet", source = "DEPT_GENOMIC" },
  ]
}
```

Les CIDR d'un département sont donnés par `terraform output departments`.

**`aliases`** : un nom (lettres, chiffres, `_`, 32 caractères au plus, pas un alias intégré) vers une liste non vide de CIDR.

**`rules`** : liste de règles.

| Champ | Défaut | Valeurs |
|---|---|---|
| `description` | obligatoire | texte unique, sans `<`, `>` ni `&` |
| `action` | obligatoire | `pass` ou `block` |
| `source`, `destination` | obligatoire | `any`, un CIDR ou un alias (intégré ou à vous) |
| `protocol` | `any` | `any`, `tcp`, `udp`, `icmp` |
| `port`, `port_end` | aucun | 1 à 65535, avec `tcp` ou `udp` ; `port_end` définit une plage |
| `interface` | `hub` | `hub` (trafic venant des départements, de l'on-prem et de la DSI, cas courant) ou `egress` (trafic arrivant de la patte egress) |
| `state` | `sloppy` | `sloppy` (état sur adresses et ports, sans contrôle des numéros de séquence TCP : les sessions survivent mieux à une bascule) ou `keep` |

**`nat_outbound`** : traduction d'adresse sortante sur la patte egress, en plus de celle des départements, déjà fournie. Champs : `description`, `source`, `destination` (défaut `any`), `target` (IPv4 ; défaut : la VIP egress).

**Alias intégrés.**

| Alias | Contenu |
|---|---|
| `DEPT_NETS` | `dept_supernet` : tous les départements |
| `DSI_EGRESS_NET` | le réseau Egress de la DSI (`cidrs.egress`) |
| `ONPREM_VPN` | les CIDR on-prem du VPN |
| `EGRESS_PGWS` | les adresses des deux Public Gateways |
| `internal_nets` | RFC1918, `dept_supernet`, les réseaux de la DSI, les CIDR on-prem du VPN et d'Interlink : ce qui n'est pas « Internet » |

**Ordre d'évaluation.** Les règles sont évaluées de haut en bas, la première qui correspond s'applique :

1. `[MGMT]` : SSH depuis les Public Gateways vers le firewall ;
2. `[HA]` : trafic du réseau de synchronisation ;
3. **vos règles, dans l'ordre de la liste** ;
4. `[EW]` : blocage entre départements (`DEPT_NETS` vers `DEPT_NETS`) ;
5. `[DSI]` : réseau Egress de la DSI vers les départements ;
6. `[VPN]` : on-prem vers départements et départements vers on-prem (seulement si `vpn` est défini) ;
7. `[EGRESS]` : départements vers Internet, non journalisée (une ligne par session saturerait le disque) ;
8. tout le reste est refusé.

Vos règles passent avant les règles par défaut : une exception au blocage inter-département s'écrit donc telle quelle. Pensez aussi à la règle `nacl_inbound` du département cible.

## Sorties utiles

`terraform output <nom>` :

| Sortie | Contenu |
|---|---|
| `access` | par nœud, la commande SSH par le bastion et le tunnel WebUI |
| `failover_commands` | par nœud, la commande de déplacement manuel des VIP |
| `egress_public_ips` | les deux IP publiques de sortie (allow-lists) |
| `vpn` | IP des passerelles, adresses BGP, `psk_secret_id` |
| `interlink` | clé d'appairage à donner au partenaire (sensible : `-json`) |
| `fw_root_password` | mot de passe root généré (sensible ; `null` si `root_password_hash`) |
| `firewall` | IP des nœuds, VIP, hash plateforme attendu par nœud |
| `project_id` | projet de la DSI |
| `departments` | par département : `project_id`, `cidrs`, `private_network_ids`, `iam_group_id`, `hybrid_bypass` |

## Options avancées

### Hub (DSI)

Ces variables du module racine transmettent leur valeur au module `hub`. `null` ou absentes : valeur par défaut du module.

| Variable | Défaut | Effet | Application |
|---|---|---|---|
| `name` | `dsi-hub` | préfixe des ressources et nom du projet créé ; ne le changez plus après le déploiement | — |
| `project_id` | `null` | projet existant où déployer ; `null` crée un projet nommé `name` | — |
| `tags` | `["landing-zone", "dsi"]` | tags des ressources | infra |
| `cidrs` | egress `10.0.4.0/24`, sync `10.255.0.0/24`, hub `172.16.0.0/24`, hybrid `10.0.5.0/24` | plan d'adressage de la DSI ; ne doit chevaucher ni `dept_supernet`, ni l'on-prem (vérifié au plan) | reconstruction |
| `dept_supernet` | `10.64.0.0/10` | bloc qui contient tous les départements (/10 ou plus grand) | à chaud côté firewall |
| `egress.gateway_type` | `VPC-GW-S` | type des Public Gateways (`VPC-GW-S` 0,1 Gbps, `M` 1, `L` 3, `XL` 10 ; bande passante seulement, pas plus de paquets par seconde) | infra ; descendre de type a coupé la sortie 20 min lors d'un essai |
| `egress.pgw_hosts` | `a = 2`, `b = 3` | numéros d'hôte des Public Gateways dans le réseau Egress | reconstruction |
| `firewall.hosts` | `election = 9`, `data = 10`, `fw1 = 11`, `fw2 = 12` | numéros d'hôte : VIP d'élection CARP (hub seul), VIP de données (hub et egress), nœuds. Les 6 numéros (avec `egress.pgw_hosts`) doivent être distincts | reconstruction |
| `firewall.disk` | `size_gb = 25`, `iops = 5000` | volume des firewalls | reconstruction |
| `firewall.system` | `timezone = "Europe/Paris"`, `dns = ["1.1.1.1"]`, `ntp = ["0.opnsense.pool.ntp.org", "1.opnsense.pool.ntp.org"]` | fuseau, DNS et NTP des firewalls | reconstruction |
| `firewall.gateway_monitors` | `a = "1.0.0.1"`, `b = "9.9.9.9"` | adresses que dpinger sonde pour juger chaque Public Gateway | reconstruction |
| `firewall.syslog` | `[]` | collecteurs syslog distants (UDP ou TCP, RFC 5424) : `host` (IPv4 ou nom), `port` (514), `transport` (`udp` ou `tcp`) ; un collecteur par couple hôte et port. Les journaux restent aussi sur le nœud | reconstruction |

Le prochain saut des routes du firewall vers le routeur du Hub (`169.254.169.254`) n'est plus une variable.

### Départements

| Variable | Défaut | Effet |
|---|---|---|
| `iam_permission_sets` | `InstancesFullAccess`, `BlockStorageFullAccess`, `LoadBalancersFullAccess`, `EdgeServicesFullAccess`, `KubernetesFullAccess`, `RelationalDatabasesFullAccess`, `ObjectStorageFullAccess`, `SecretManagerFullAccess`, `ObservabilityFullAccess`, `IPAMFullAccess`, `PrivateNetworksReadOnly`, `VPCReadOnly` | droits du groupe IAM `dept-<nom>` sur son projet, jamais sur le réseau (ni VPC, ni passerelle, ni VPN, ni Interlink). Même valeur pour tous les départements. Retirer `InstancesFullAccess` empêche un département d'attacher une IP publique à une instance ; retirer `LoadBalancersFullAccess` ou `EdgeServicesFullAccess` ferme ses expositions Internet |

Exemple, sans droit d'attacher une IP publique :

```hcl
iam_permission_sets = [
  "BlockStorageFullAccess",
  "RelationalDatabasesFullAccess",
  "ObjectStorageFullAccess",
  "PrivateNetworksReadOnly",
  "VPCReadOnly",
]
```
