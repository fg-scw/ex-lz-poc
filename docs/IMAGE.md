# Image golden OPNsense

## Contenu

OPNsense nano officiel (SHA-256 vérifié) et le plugin `os-scw-lz`, sans aucun secret. La construction échoue si une clé ou un mot de passe s'y trouve. Secrets et configuration arrivent par les métadonnées de l'instance au premier démarrage.

## Prérequis

- CLI `scw` configurée, avec les droits Block Storage et Instance.
- Un hôte de build : une instance OPNsense de même version majeure, dans la zone de build, joignable en SSH, avec environ 4 Go libres dans `/var/tmp`.
- Sur le poste : `bash`, `ssh`, `curl`, `tar`, `sed`, `comm`.

## Construire l'image

```bash
BUILD_SERVER=<zone>/<uuid-hôte-de-build> \
BUILD_SSH=root@<ip-hôte-de-build> BUILD_SSH_OPTS="-J <bastion>" \
ZONES="<zone-1> <zone-2>" BUCKET=<bucket> PLUGIN_VERSION=<version-plugin> \
image/build.sh
```

| Variable | Défaut | Rôle |
|---|---|---|
| `BUILD_SERVER` | obligatoire | `<zone>/<uuid>` de l'hôte de build |
| `BUILD_SSH` | obligatoire | destination SSH de l'hôte de build |
| `BUILD_SSH_OPTS` | vide | options SSH, par exemple un bastion (`-J`) |
| `OPNSENSE_VERSION` | `26.1` | version d'OPNsense |
| `NANO_SHA256` | lu dans le fichier de sommes officiel | empreinte attendue de l'image nano |
| `PLUGIN_VERSION` | `1.0.0` | version du paquet `os-scw-lz` |
| `IMAGE_NAME` | `opnsense-<version>-scwlz-<version plugin>` | nom des snapshots et du qcow2 |
| `ZONES` | zone de l'hôte de build | zones où publier |
| `BUCKET` | aucun | bucket du qcow2 ; obligatoire si `ZONES` dépasse la zone de l'hôte (même région) |
| `PROJECT_ID` | projet par défaut de `scw` | projet des snapshots |
| `DISK_GB` | `25` | taille du volume de travail |

Le script crée un volume de travail, lance `bake.sh` sur l'hôte de build, fait un snapshot puis supprime le volume ; si `BUCKET` est donné, il exporte un qcow2 et l'importe dans les autres zones. `bake.sh` n'est pas lancé à la main : il efface le disque qu'on lui passe.

## Renseigner le snapshot

Le snapshot de chaque zone va dans `firewall.nodes.<nœud>.snapshot_id`, au format `<zone>/<uuid>` :

```terraform
firewall = {
  nodes = {
    fw1 = { zone = "<zone-1>", snapshot_id = "<zone-1>/<uuid du snapshot>" }
    fw2 = { zone = "<zone-2>", snapshot_id = "<zone-2>/<uuid du snapshot>" }
  }
}
```

Chaque nœud doit avoir exactement une source (`image`, `volume_id` ou `snapshot_id`). Pour une autre zone ou un autre projet, importez le qcow2 :

```bash
scw block snapshot import-from-object-storage zone=<zone> bucket=<bucket> \
  key=releases/<IMAGE_NAME>.qcow2 name=<IMAGE_NAME> [project-id=<projet>]
```

## Changer de version

1. Relancez `image/build.sh` avec `OPNSENSE_VERSION` et/ou `PLUGIN_VERSION`.
2. Remplacez `snapshot_id` dans `terraform.tfvars` par le nouveau snapshot de chaque zone.
3. Appliquez un nœud à la fois. Voir [exploitation](../README.md#exploitation).

## Plugin os-scw-lz

- `sync.sh` (au démarrage et chaque minute) lit secrets, configuration et réglages de bascule dans les métadonnées, puis efface les secrets des métadonnées après les avoir stockés dans `/conf/scwlz/secrets.env`.
- Un changement de politique (règles, NAT, routes) s'applique à chaud ; un changement de plateforme n'est appliqué que sur un nœud neuf.
- `vip.sh` (hook CARP et chaque minute) déplace les VIP de données vers le nœud MASTER ; un nœud BACKUP rend au pair celles qu'il détient encore.

Secrets reçus (`opnsense_secrets`) : `ROOT_HASH`, `ADMIN_KEYS_B64`, `CARP_PASS`, `SCW_SECRET_KEY`.

- La clé API du hook (`IPAMFullAccess`) est limitée au projet DSI et aux IP des Public Gateways, que la sortie Internet des départements partage : une clé fuitée reste utilisable depuis une VM de département. Rotation dans [exploitation](../README.md#exploitation).
- `vip.sh` passe la clé à `curl` en argument, donc visible dans la liste des processus pendant l'appel ; seul root existe sur le firewall, risque faible.

## Diagnostic

```bash
ssh -J <bastion> root@<ip-du-firewall> 'grep -E "scwlz" /var/log/system/latest.log | tail -n 50'
```

Les messages portent l'étiquette `scwlz` (sync) ou `scwlz-vip` (vip). Les plus utiles :

| Message | Sens |
|---|---|
| `rebuild this node to apply it` | changement de plateforme en attente d'une reconstruction |
| `failed: HTTP` | déplacement de VIP échoué, voir [dépannage](../README.md#dépannage) |
| `split brain` | deux MASTER et le pair répond : à investiguer |
| `metadata unreachable` | métadonnées injoignables au démarrage |
| `configuration waits for its secrets` | configuration reçue, secrets pas encore là |
