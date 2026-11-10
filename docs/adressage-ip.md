# Plan d'adressage IP

## Réseau du laboratoire

| Paramètre | Valeur |
|---|---|
| Réseau virtuel | VMware Workstation Pro, **VMnet8 (NAT)** |
| Sous-réseau | `192.168.50.0/24` |
| Hôte (poste physique) | `192.168.50.1` (interface `vmnet8`) |
| Passerelle NAT VMware | `192.168.50.2` — sortie Internet pour les mises à jour |
| DNS du laboratoire | `192.168.50.10` (WIN-DC01), redirecteur vers `192.168.50.2` |
| Domaine | `infraready.test` (NetBIOS `INFRAREADY`) |
| Adressage des serveurs | **fixe** (pas de DHCP) |

Absence de conflit vérifiée avant usage : aucune interface ni route du poste n'utilisait `192.168.50.0/24` (sujet §4.4).

## Serveurs

| Machine | Adresse | Nom DNS (A + PTR) | Système | Rôle |
|---|---|---|---|---|
| WIN-DC01 | `192.168.50.10` | `win-dc01.infraready.test` | Windows Server 2025 | AD DS, DNS, journaux Windows |
| OPS01 | `192.168.50.20` | `ops01.infraready.test` | Ubuntu Server 26.04 | Ansible, Git, Prometheus, Grafana |
| LINUX01 | `192.168.50.30` | `linux01.infraready.test` | Ubuntu Server 26.04 | nginx, stockage `/srv/data`, comptes Linux |

**Écart par rapport au sujet** : le sujet propose LINUX01 en `.20` et OPS01 en `.30`. Les deux adresses ont été inversées lors de l'installation. L'inventaire Ansible utilise les noms DNS et n'est pas affecté ; la configuration Prometheus utilise les adresses (voir ci-dessous).

## Configuration par machine

**WIN-DC01** — IPv4 statique `192.168.50.10/24`, passerelle `192.168.50.2`, DNS `127.0.0.1` (lui-même, positionné par la promotion AD). Zone directe `infraready.test`, zone inversée `50.168.192.in-addr.arpa`, redirecteur `192.168.50.2`.

**LINUX01 / OPS01** — Netplan `/etc/netplan/50-cloud-init.yaml`, interface `ens33` :

```yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.50.30/24]      # .20 sur OPS01
      routes:
        - to: default
          via: 192.168.50.2
      nameservers:
        addresses: [192.168.50.10]
        search: [infraready.test]
```

`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` (`network: {config: disabled}`) empêche cloud-init de régénérer ce fichier au démarrage.

## Ports et flux

| Destination | Port | Source autorisée | Usage |
|---|---|---|---|
| LINUX01 | 22/tcp | 192.168.50.0/24 | SSH (Ansible, poste admin) |
| LINUX01 | 80/tcp | 192.168.50.0/24 | site nginx |
| LINUX01 | 9100/tcp | 192.168.50.20 | node_exporter → Prometheus |
| OPS01 | 22/tcp | 192.168.50.0/24 | SSH |
| OPS01 | 3000/tcp | 192.168.50.0/24 | Grafana |
| OPS01 | 9090/tcp | 192.168.50.0/24 | Prometheus |
| OPS01 | 9100/tcp | 192.168.50.20 | node_exporter local |
| WIN-DC01 | 5986/tcp | 192.168.50.20 | WinRM HTTPS (Ansible) |
| WIN-DC01 | 9182/tcp | 192.168.50.20 | windows_exporter → Prometheus |
| WIN-DC01 | 53, 88, 389… | réseau du labo | DNS et AD (règles des rôles AD DS / DNS) |

Pourquoi Prometheus vise les **adresses** et non les noms : le DNS est porté par WIN-DC01. Si le contrôleur tombe, Prometheus continue de collecter LINUX01 et OPS01 et montre WIN-DC01 hors ligne, au lieu de tout perdre.
