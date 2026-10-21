# Configuration

Toute la configuration se fait dans `terraform.tfvars`, copie de `terraform.tfvars.example` (non versionnée). Pour déployer, voir [Déploiement](../README.md#déploiement).

Une option sans défaut est obligatoire. `null` signifie « valeur par défaut du module ».

Au moins un des deux liens, `vpn` ou `interlink`, est obligatoire.

## Backend et variables d'environnement

Un seul state, clé `landing-zone/terraform.tfstate`, verrou natif (`use_lockfile`). Le bucket se passe à l'init : `terraform init -backend-config="bucket=$STATE_BUCKET"`.

| Variable | Défaut | Effet |
|---|---|---|
| `SCW_ACCESS_KEY`, `SCW_SECRET_KEY` | obligatoire | clé API Scaleway d'organisation, lue par le provider |
| `SCW_DEFAULT_ORGANIZATION_ID` | obligatoire | organisation qui reçoit les projets |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | obligatoire | clés Object Storage du bucket du state |
| `STATE_BUCKET` | obligatoire | nom du bucket du state (pour `-backend-config`) |

La région (`fr-par`) et la zone par défaut (`fr-par-1`) sont écrites dans les blocs `provider` et `backend` de `main.tf`.

## Exemple minimal

```hcl
vpn = {
  customer_gateway_ip = "198.51.100.1"
  customer_asn        = 65010
  onprem_cidrs        = ["192.168.0.0/16"]
}

departments = {
  genomic = { index = 1 }
}
```

## Variables du module racine

| Variable | Type | Défaut | Effet |
|---|---|---|---|
| `vpn` | objet | `null` | VPN site à site vers l'on-prem, voir [`vpn`](#vpn) |
| `interlink` | objet | `null` | Interlink vers l'on-prem, voir [`interlink`](#interlink) |
| `departments` | map d'objets | `{}` | les départements, voir [Départements](#départements) |
| `iam_permission_sets` | liste | `null` | droits du groupe IAM de chaque département |
| `name`, `project_id`, `tags`, `cidrs`, `dept_supernet` | | `null` | surcharges avancées du hub, voir [Hub](#hub) |

Au moins un de `vpn` et `interlink` est requis, sinon le plan échoue : sans lien, les départements n'ont pas de sortie.

**Lien qui porte le trafic.** Les départements sortent par Interlink s'il est défini, sinon par le VPN. Seul ce lien annonce `dept_supernet` à l'on-prem. Les deux liens acceptent `0.0.0.0/0` et leurs CIDR on-prem. L'on-prem doit annoncer `0.0.0.0/0` sur le lien qui porte le trafic.

### `vpn`

Un tunnel IPsec avec BGP est créé par zone. Il porte le trafic des départements quand `interlink` n'est pas défini. L'on-prem doit alors annoncer `0.0.0.0/0`. Les deux tunnels portent du trafic en même temps, réparti flux par flux dans les deux sens : ils doivent aboutir au même firewall on-prem, ou au même cluster stateful.

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
| `zones` | `a = "fr-par-1"`, `b = "fr-par-2"` | zone de chaque passerelle VPN |
| `ciphers` | `ike` et `esp` : `aes256`, `sha256`, `modp2048` | propositions IKE (phase 1) et ESP (phase 2) : `encryption`, `integrity`, `dh_group` |
| `bgp_links` | `a` : `169.254.100.1/30` (Scaleway), `169.254.100.2/30` (on-prem) ; `b` : `169.254.100.5/30`, `169.254.100.6/30` | adresses BGP `/30` des deux tunnels : `scaleway` et `onprem` |

### `interlink`

```hcl
interlink = {
  pop_id         = "fr-par/<uuid du PoP>"
  bandwidth_mbps = 1000
  partner_id     = "fr-par/<uuid du partenaire>"
  onprem_cidrs   = ["10.10.0.0/16"]
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `pop_id`, `bandwidth_mbps`, `onprem_cidrs` | obligatoires | PoP, débit, réseaux on-prem |
| `partner_id` | `null` | lien hébergé par un partenaire |
| `connection_id` | `null` | lien en propre |
| `peer_asn`, `vlan` | `null` | pour le lien en propre uniquement |

Exactement un de `partner_id` ou `connection_id` est requis. Quand il est défini, il porte le trafic des départements (via le Hub) et l'on-prem doit annoncer `0.0.0.0/0` dessus. Les VPC Private des départements avec `hybrid_bypass` le rejoignent aussi directement. La clé d'appairage à remettre au partenaire est dans la sortie `interlink` (sensible : `terraform output -json interlink`).

## Départements

Clé = nom du département (2 à 24 caractères : minuscules, chiffres et tirets, commence par une lettre). C'est la source unique du plan d'adressage et de la politique réseau de chaque département. Ajouter une entrée crée son projet, ses VPC et ses NACL ; la retirer les détruit.

```hcl
departments = {
  genomic = {
    index         = 1
    hybrid_bypass = true
    nacl_inbound = [
      {
        to          = "private"
        source      = "192.168.10.0/24"
        port        = 8080
        description = "On-prem clients to genomic backends"
      },
    ]
  }
  hr = { index = 2 }
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `index` | obligatoire | entier unique de 0 à 1023, **permanent**. Il fixe le Pub (/22 dans `10.64.0.0/12`) et le Private (/21 dans `10.96.0.0/11`). Ne le changez pas pour un département en service. Gardez l'index d'un département supprimé réservé tant que son projet n'est pas entièrement supprimé |
| `hybrid_bypass` | `false` | relie le VPC Private au VPC Hybrid (Interlink, direct vers l'on-prem). **Exige `interlink`**, sinon le plan échoue. Ajoute 2 connecteurs de peering |
| `nacl_inbound` | `[]` | flux autorisés **vers** le département depuis l'extérieur (on-prem, DSI). Un autre département comme `source` n'a aucun effet |

Deux `index` identiques font échouer le plan.

**Éléments de `nacl_inbound` :**

| Champ | Défaut | Valeurs |
|---|---|---|
| `to` | obligatoire | `pub` ou `private` |
| `source` | obligatoire | CIDR |
| `protocol` | `TCP` | `ANY`, `TCP`, `UDP`, `ICMP` |
| `port`, `port_end` | `0` (tous les ports) ; `port_end` = `port` | numéro de port, ou plage avec `port_end` |
| `description` | `Inbound from <source>` | texte libre |

**Sécurité des NACL.** Les NACL sont sans état et refusent par défaut. Elles acceptent toujours :

- tout trafic sortant ;
- Pub vers Private dans le département ;
- ICMP ;
- TCP et UDP sur les ports 32768-65535, **depuis toute source**. Un service qui écoute sur un port de cette plage est donc joignable depuis l'extérieur du département, sauf depuis un autre département (bloqué par le Hub).

Il n'y a pas de firewall dans le hub : une règle `drop` de la NACL du VPC Hub bloque le trafic entre départements, dans les deux sens et sur tous les ports. Une règle `nacl_inbound` qui désigne un autre département comme `source` n'a donc aucun effet tant que cette règle existe. Ce qui vient de l'on-prem est aussi filtré par les firewalls on-prem, sauf par le bypass Interlink. Le trafic à l'intérieur d'un Private Network n'est jamais filtré.

Chaque département reçoit un groupe IAM `dept-<nom>` ; ses ressources portent le préfixe `dept-<nom>` et le tag `department:<nom>`. Les CIDR, l'ID du projet et les Private Networks de chaque département sortent dans `departments`.

## Options avancées

### Hub

Ces variables du module racine sont transmises au module `hub`. `null` ou absentes : valeur par défaut du module.

| Variable | Défaut | Effet |
|---|---|---|
| `name` | `dsi-hub` | préfixe des ressources et nom du projet créé. Ne pas le changer après déploiement |
| `project_id` | `null` | projet existant où déployer ; `null` crée un projet nommé `name` |
| `tags` | `["landing-zone", "dsi"]` | tags de toutes les ressources du hub |
| `cidrs` | `egress` `10.0.4.0/24`, `hub` `172.16.0.0/24`, `hybrid` `10.0.5.0/24` | plan d'adressage de la DSI. Ne doit chevaucher ni `dept_supernet` ni l'on-prem (contrôlé au plan) |
| `dept_supernet` | `10.64.0.0/10` | bloc qui contient tous les départements (/10 ou plus large) |

### Départements

| Variable | Défaut | Effet |
|---|---|---|
| `iam_permission_sets` | `InstancesFullAccess`, `BlockStorageFullAccess`, `LoadBalancersFullAccess`, `EdgeServicesFullAccess`, `KubernetesFullAccess`, `RelationalDatabasesFullAccess`, `ObjectStorageFullAccess`, `SecretManagerFullAccess`, `ObservabilityFullAccess`, `IPAMFullAccess`, `PrivateNetworksReadOnly`, `VPCReadOnly` | droits du groupe IAM `dept-<nom>` sur son projet, identiques pour tous les départements. Jamais de droits sur le réseau (VPC, passerelles, VPN, Interlink) |

**Sécurité IAM.** Retirer `InstancesFullAccess`, `LoadBalancersFullAccess` ou `KubernetesFullAccess` ferme l'exposition directe vers Internet. Les LB et Edge Services d'un département ne passent pas par l'on-prem.

Exemple, sans droit d'attacher une IP publique ni de créer des LB :

```hcl
iam_permission_sets = [
  "BlockStorageFullAccess",
  "RelationalDatabasesFullAccess",
  "ObjectStorageFullAccess",
  "PrivateNetworksReadOnly",
  "VPCReadOnly",
]
```

## Sorties utiles

`terraform output <nom>` :

| Sortie | Contenu |
|---|---|
| `vpn` | IP des passerelles, adresses BGP, `psk_secret_id` |
| `interlink` | clé d'appairage à remettre au partenaire (sensible : `-json`) |
| `departments` | par département : `project_id`, `cidrs`, `private_network_ids`, `iam_group_id`, `hybrid_bypass` |
