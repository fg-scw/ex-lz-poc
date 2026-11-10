# Lab Wallix : VPN et bastion HA

Lab séparé de la landing zone, avec son propre state local. Il répond à deux questions d'onboarding : comment raccorder un site qui ne parle pas BGP, et comment mettre deux bastions Wallix 12 derrière un seul point d'entrée.

## Verdict

Le VPN site-à-site Scaleway n'échange les préfixes qu'en BGP. La FAQ et la page Concepts le disent, et la demande de routes statiques sur la passerelle n'est pas livrée. Le contournement qui marche est déjà celui du tutoriel [Site-to-Site VPN et strongSwan](https://www.scaleway.com/en/docs/tutorials/s2s-vpn-strongswan/) (relecture du 31 mars 2026) :

- une VM on-prem, avec hyperviseur, est le customer gateway ;
- elle seule parle BGP (FRR, ASN privé, distinct de `12876`) et IPsec (strongSwan) ;
- les serveurs internes, Wallix compris, ont une route statique `ip route add <cidr Scaleway> via <ip privée du customer gateway>` ;
- les CIDR on-prem ne chevauchent pas les CIDR Scaleway. La landing zone refuse déjà un overlap entre `cidrs`, `dept_supernet`, `vpn.onprem_cidrs` et `interlink`.

Le BGP reste sur cette VM. La route statique est sur les serveurs internes. `prefix_filter_in` reçoit les réseaux on-prem, `prefix_filter_out` reçoit ce qu'il faut joindre côté Scaleway (ici l'adresse du LB). On active la propagation une fois ces filtres en place.

Côté bastion, la reco tient avec l'algorithme `first`. Round-robin, le défaut du LB, répartit les nouvelles sessions entre les deux nœuds quand les deux health checks TCP réussissent. `first` envoie chaque nouvelle session au premier serveur de la liste qui a encore un slot. Sans `max_connections`, c'est le maître (`.11`) tant qu'il écoute, puis l'esclave (`.12`).

Trois limites, mesurées par le test hors ligne :

- La bascule ferme les sessions en cours (`shutdown_sessions`). Une session RDP ou SSH déjà ouverte tombe, en actif/passif comme en actif/actif. Wallix ne la reprend pas sur l'autre nœud.
- Le retour sur le maître est automatique dès qu'il réécoute. En réplication SQL master/slave, les écritures faites sur l'esclave pendant la panne ne remontent pas. On laisse le maître hors du LB tant que `bastion-replication` n'a pas été reconstruite dans le bon sens, ou on assume de perdre ces écritures. Le LB Scaleway n'a pas de serveur de secours qui resterait passif après le retour du maître.
- Le health check est par port. Un 3389 fermé ne doit pas retirer le nœud du 22 ni du 443.

Wallix 12 a retiré DRBD. La HA est la réplication SQL (`bastion-replication`), master/slave de préférence : on n'écrit pas sur l'esclave, les mots de passe et les approbations restent sur le maître. Les tables d'audit ne sont pas répliquées. Les enregistrements sont locaux, sauf un NFS (2049) ou un CIFS (445) configuré dans l'appliance. Le File Storage Scaleway est créé à part, non attaché en virtio-fs : Wallix doit monter le NFS lui-même. Avec `first`, un seul nœud écrit à la fois. Le verrouillage NFS reste à confirmer avec Wallix.

Le RDP passe par un seul frontend TCP 3389. Wallix démux les utilisateurs vers les cibles, là où une règle NAT statique en impose une par cible. Le mode `banner` le montre au niveau transport. Une vraie session multi-utilisateurs attend la licence, l'initialisation du chiffrement et les cibles.

L'image `wallix-bastion-12.3.6` (`9a4410b3-f8b4-4aba-aab5-73447ce5710e`) est en `fr-par-1`. Les deux nœuds et le LB y sont : la perte de la zone les arrête ensemble. Le LB sait joindre un backend d'une autre zone via le VPC une fois l'image copiée. Deux instances sont créées depuis l'image, puis `bastion-replication` s'installe sur le maître. Une VM déjà initialisée conserve son UUID, donc elle ne sert pas de modèle à cloner.

## Déployer

Depuis `labs/wallix-ha`, avec une clé d'API du projet (`SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_DEFAULT_PROJECT_ID` ou `SCW_DEFAULT_ORGANIZATION_ID`).

```bash
cp terraform.tfvars.example terraform.tfvars   # admin_cidrs = votre IP /32
terraform init
terraform plan
terraform apply
```

`mode = "banner"` déploie deux Ubuntu qui répondent `a` ou `b` sur 22, 443 et 3389. C'est le test qui prouve le pinning. `mode = "wallix"` démarre l'appliance. Le LB reste privé. La sonde a la seule IP publique, SSH depuis `admin_cidrs`.

`terraform output -raw probe_private_key` donne la clé root de la sonde. `terraform output lb_private_ip` est le point d'entrée.

Si l'appliance ne prend pas d'adresse sur la carte privée (elle n'a en général pas la règle udev Scaleway `72-scw-vpc-iface`, et cette carte est ajoutée après le premier boot), poser `expose_bastion_admin = true` ouvre 443 et 2242 depuis `admin_cidrs` le temps de configurer l'adresse dans System > Network. Le LB ne devient pas public.

`recordings_filesystem = true` crée un File Storage régional, sans l'attacher à l'instance.

Le LB, les instances et le File Storage sont facturés. `terraform destroy` une fois le test fini.

## Test hors ligne

Aucun appel Scaleway.

```bash
python3 tests/lb_active_passive.py
terraform init -backend=false
terraform test
```

Le script Python vérifie le round-robin, le pinning, la bascule, la survie des autres ports, le retour automatique sur le maître, le débordement si `max_connections` vaut 1, et six clients RDP vers trois cibles par le seul port 3389. Il rejoue la bascule sur de vrais sockets.

## Test live

`scripts/failover.sh` éteint des instances. Il exige `SCW_SECRET_KEY` et un `apply` déjà fait. Il se connecte à la sonde et parle à l'API Instance.

En mode `banner` : 20 connexions par port vers le LB aboutissent sur `a`, l'extinction de `b` laisse `a` en place, l'extinction de `a` envoie les nouvelles sessions sur `b`, une session tenue est coupée quand `b` tombe, le retour des deux nœuds renvoie les nouvelles sessions sur `a`.

En mode `wallix` : le script affiche quels ports répondent sur le LB et sur chaque nœud. 22 et 3389 restent fermés tant que le proxy n'est pas configuré. S'il trouve un port ouvert des deux côtés, il éteint `a` puis `b` et vérifie que le LB répond encore. Il ne lance pas `bastion-replication` et n'ouvre pas de session RDP.

## Limites

- Réplication SQL, coffre, licence et enregistrements restent à faire dans l'appliance, avec les mots de passe `wabadmin` / `wabsuper`.
- Le failback LB est automatique. La procédure d'exploitation Wallix, elle, doit retenir le maître tant que la réplication n'est pas réalignée.
- Deux nœuds dans la même zone : une panne de `fr-par-1` les emmène tous les deux.
- La carte privée est branchée après la création de l'instance. Ubuntu marketplace la configure par DHCP. L'image Wallix, peut-être pas.

## Détruire

```bash
terraform destroy
```
