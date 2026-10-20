# Configuration

Toute la configuration se fait dans `terraform.tfvars`, copie de `terraform.tfvars.example` (non versionnée). Pour déployer, voir [Déploiement](../README.md#déploiement).

Une option sans défaut est obligatoire. `null` signifie « valeur par défaut du module ».

**Application d'un changement :**

- **À chaud** : appliqué en direct sur les firewalls, sans reconstruction.
- **Infra** : l'apply modifie les ressources Scaleway seulement.
- **Reconstruction** : l'apply ne touche pas un nœud en service. Reconstruisez chaque nœud, un à la fois ([Exploitation](../README.md#exploitation)).

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
admin_cidrs           = ["203.0.113.10/32"]
admin_ssh_public_keys = ["ssh-ed25519 AAAA... admin@dsi"]

firewall = {
  nodes = {
    fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid du snapshot>" }
    fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid du snapshot>" }
  }
}

departments = {
  genomic = { index = 1 }
}
```

## Variables du module racine

| Variable | Type | Défaut | Effet | Application |
|---|---|---|---|---|
| `admin_cidrs` | liste de CIDR | obligatoire | IP publiques autorisées sur le bastion SSH des Public Gateways. `0.0.0.0/0` est refusé | Infra |
| `admin_ssh_public_keys` | liste | obligatoire | clés OpenSSH (ed25519, rsa, ecdsa) des bastions et du compte root des firewalls | bastions : Infra ; firewalls : Reconstruction |
| `firewall` | objet | obligatoire | OPNsense HA, voir [`firewall`](#firewall) | Reconstruction |
| `vpn` | objet | `null` | VPN site à site inspecté par le firewall, voir [`vpn`](#vpn) | Infra |
| `interlink` | objet | `null` | lien sans inspection vers le VPC Hybrid, voir [`interlink`](#interlink) | Infra |
| `policy` | objet | `{}` | règles, alias et NAT du firewall, voir [`policy`](#policy) | À chaud |
| `departments` | map d'objets | `{}` | les départements, voir [`departments`](#departments) | Infra |
| `iam_permission_sets` | liste | `null` | droits du groupe IAM de chaque département, voir [Départements](#départements) | Infra |
| `name`, `project_id`, `tags`, `cidrs`, `dept_supernet`, `egress` | | `null` | surcharges avancées du hub, voir [Hub](#hub) | voir [Hub](#hub) |

### `firewall`

Chaque nœud (`fw1` et `fw2` exactement) a une `zone` (`fr-par-1` ou `fr-par-2`) et **un seul** des trois champs suivants :

- `snapshot_id` : `<zone>/<uuid>` du snapshot de l'image ([IMAGE.md](IMAGE.md)) ;
- `volume_id` : `<zone>/<uuid>` d'un volume SBS existant ;
- `image` : image ou identifiant d'image local à la zone.

Les zones des nœuds fixent aussi celles des Public Gateways et des passerelles VPN.

| Champ | Défaut | Effet |
|---|---|---|
| `nodes` | obligatoire | `fw1` et `fw2`, chacun avec `zone` et un des champs ci-dessus |
| `instance_type` | `POP2-2C-8G` | taille des firewalls |
| `root_password_hash` | `null` | hash bcrypt du mot de passe root (`htpasswd -nbB root <mot de passe>`). `null` génère un mot de passe, lisible dans la sortie `fw_root_password`. Reconstruction |
| `syslog` | `[]` | collecteurs syslog distants. Reconstruction |
| `disk`, `hosts`, `system`, `gateway_monitors` | voir [Hub](#hub) | réglages avancés |

```hcl
firewall = {
  root_password_hash = "$2y$10$..."
  syslog             = [{ host = "10.0.4.5", port = 514, transport = "udp" }]
  nodes = {
    fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid>" }
    fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid>" }
  }
}
```

### `vpn`

Un tunnel IPsec avec BGP est créé par zone. Le trafic on-prem passe par le firewall.

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

Exactement un de `partner_id` ou `connection_id` est requis. Seuls les VPC Private des départements avec `hybrid_bypass` atteignent ce lien, sans firewall. La clé d'appairage à remettre au partenaire est dans la sortie `interlink` (sensible : `terraform output -json interlink`).

### `policy`

Optionnel. Il étend la politique du firewall et s'applique à chaud, sans reconstruction. Trois sections, toutes optionnelles :

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

Les CIDR d'un département se lisent avec `terraform output departments`.

**`aliases`** : nom (commence par une lettre, puis lettres, chiffres ou `_`, 32 caractères au plus, pas un alias intégré) vers une liste non vide de CIDR.

**`rules`** :

| Champ | Défaut | Valeurs |
|---|---|---|
| `description` | obligatoire | unique, sans `<`, `>` ni `&` |
| `action` | obligatoire | `pass` ou `block` |
| `source`, `destination` | obligatoire | `any`, un CIDR, un alias intégré ou un alias à vous |
| `protocol` | `any` | `any`, `tcp`, `udp`, `icmp` |
| `port`, `port_end` | aucun | 1 à 65535, avec `tcp` ou `udp` ; `port_end` ouvre une plage |
| `interface` | `hub` | `hub` (trafic des départements, de l'on-prem et de la DSI) ou `egress` (trafic de la patte egress) |
| `state` | `sloppy` | `sloppy` (suivi sans contrôle des numéros de séquence TCP) ou `keep` |

**`nat_outbound`** : SNAT sur la patte egress, en plus de celui des départements. Champs : `description` (obligatoire), `source` (obligatoire), `destination` (défaut `any`), `target` (IPv4, défaut : la VIP egress).

**Alias intégrés** :

| Alias | Contenu |
|---|---|
| `DEPT_NETS` | `dept_supernet` : tous les départements |
| `DSI_EGRESS_NET` | le réseau Egress de la DSI (`cidrs.egress`) |
| `ONPREM_VPN` | les CIDR on-prem du VPN |
| `EGRESS_PGWS` | les adresses des deux Public Gateways |
| `internal_nets` | RFC 1918, `dept_supernet`, les réseaux de la DSI, les CIDR on-prem du VPN et d'Interlink |

**Ordre d'évaluation.** Première règle qui correspond, de haut en bas :

1. `[MGMT]` : SSH depuis les Public Gateways vers le firewall ;
2. `[HA]` : synchronisation entre nœuds ;
3. **vos règles**, dans l'ordre de la liste ;
4. `[EW]` : blocage entre départements ;
5. `[DSI]` : réseau Egress de la DSI vers les départements ;
6. `[VPN]` : on-prem vers départements et inverse (si `vpn` est défini) ;
7. `[EGRESS]` : départements vers Internet, sans journalisation ;
8. tout le reste est refusé.

Vos règles passent avant `[EW]` : une exception au blocage inter-département s'écrit telle quelle. Pensez aussi à la règle `nacl_inbound` du département cible.

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
| `index` | obligatoire | entier unique de 0 à 1023, **permanent**. Il fixe le Pub (/22 dans `10.64.0.0/12`) et le Private (/21 dans `10.96.0.0/11`). Ne le changez pas pour un département en service. Gardez l'index d'un département supprimé réservé tant que son projet n'est pas entièrement supprimé |
| `hybrid_bypass` | `false` | relie le VPC Private au VPC Hybrid (Interlink, sans firewall). **Exige `interlink`**, sinon le plan échoue. Ajoute 2 connecteurs de peering |
| `nacl_inbound` | `[]` | flux autorisés **vers** le département depuis l'extérieur (on-prem, DSI, autre département) |

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
- TCP et UDP sur les ports 32768-65535, **depuis toute source**. Un service qui écoute sur un port de cette plage est donc joignable depuis l'extérieur du département.

Ce qui vient du Hub (autre département, on-prem par VPN, DSI) reste filtré par le firewall. Seuls le bypass Interlink et Pub vers Private ne le sont pas. Le trafic à l'intérieur d'un Private Network n'est jamais filtré.

Chaque département reçoit un groupe IAM `dept-<nom>` ; ses ressources portent le préfixe `dept-<nom>` et le tag `department:<nom>`. Les CIDR, l'ID du projet et les Private Networks de chaque département sortent dans `departments`.

## Options avancées

### Hub

Ces variables du module racine sont transmises au module `hub`. `null` ou absentes : valeur par défaut du module.

| Variable | Défaut | Effet |
|---|---|---|
| `name` | `dsi-hub` | préfixe des ressources et nom du projet créé. Ne pas le changer après déploiement |
| `project_id` | `null` | projet existant où déployer ; `null` crée un projet nommé `name` |
| `tags` | `["landing-zone", "dsi"]` | tags de toutes les ressources du hub |
| `cidrs` | `egress` `10.0.4.0/24`, `sync` `10.255.0.0/24`, `hub` `172.16.0.0/24`, `hybrid` `10.0.5.0/24` | plan d'adressage de la DSI. Ne doit chevaucher ni `dept_supernet` ni l'on-prem (contrôlé au plan) |
| `dept_supernet` | `10.64.0.0/10` | bloc qui contient tous les départements (/10 ou plus large) |
| `egress.gateway_type` | `VPC-GW-S` | type des Public Gateways (bande passante) |
| `egress.pgw_hosts` | `a = 2`, `b = 3` | numéros d'hôte des Public Gateways dans le réseau Egress. Reconstruction |
| `firewall.hosts` | `election = 9`, `data = 10`, `fw1 = 11`, `fw2 = 12` | numéros d'hôte des VIP d'élection CARP (hub), des VIP de données (hub et egress) et des nœuds. Les 6 numéros (avec `egress.pgw_hosts`) doivent être distincts. Reconstruction |
| `firewall.disk` | `size_gb = 25`, `iops = 5000` | volume des firewalls. Reconstruction |
| `firewall.system` | `timezone = "Europe/Paris"`, `dns = ["1.1.1.1"]`, `ntp = ["0.opnsense.pool.ntp.org", "1.opnsense.pool.ntp.org"]` | fuseau, DNS et NTP des firewalls. Reconstruction |
| `firewall.gateway_monitors` | `a = "1.0.0.1"`, `b = "9.9.9.9"` | adresses que dpinger sonde pour juger chaque Public Gateway. Reconstruction |
| `firewall.syslog` | `[]` | collecteurs syslog distants (RFC 5424). Champs : `host` (IPv4 ou nom d'hôte), `port` (514), `transport` (`udp` ou `tcp`, défaut `udp`). Un collecteur par couple hôte et port. Les journaux restent aussi sur le nœud. Reconstruction |

### Départements

| Variable | Défaut | Effet |
|---|---|---|
| `iam_permission_sets` | `InstancesFullAccess`, `BlockStorageFullAccess`, `LoadBalancersFullAccess`, `EdgeServicesFullAccess`, `KubernetesFullAccess`, `RelationalDatabasesFullAccess`, `ObjectStorageFullAccess`, `SecretManagerFullAccess`, `ObservabilityFullAccess`, `IPAMFullAccess`, `PrivateNetworksReadOnly`, `VPCReadOnly` | droits du groupe IAM `dept-<nom>` sur son projet, identiques pour tous les départements. Jamais de droits sur le réseau (VPC, passerelles, VPN, Interlink) |

**Sécurité IAM.** Retirer `InstancesFullAccess`, `LoadBalancersFullAccess` ou `KubernetesFullAccess` ferme l'exposition directe vers Internet. Les LB et Edge Services d'un département ne passent pas par le firewall.

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
| `egress_public_ips` | les deux IP publiques de sortie, pour les allow-lists |
| `vpn` | IP des passerelles, adresses BGP, `psk_secret_id` |
| `interlink` | clé d'appairage à remettre au partenaire (sensible : `-json`) |
| `fw_root_password` | mot de passe root généré (sensible ; `null` si `root_password_hash` est défini) |
| `departments` | par département : `project_id`, `cidrs`, `private_network_ids`, `iam_group_id`, `hybrid_bypass` |
