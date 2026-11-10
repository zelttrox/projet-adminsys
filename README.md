# InfraReady

Projet fil rouge — Administration systèmes Linux/Windows, Bachelor 3 Cybersécurité.
Binôme : **VICENTE Romain**, **GRANANA Enzo**.

Infrastructure de laboratoire de trois machines virtuelles, déployée, automatisée et supervisée :

| Machine | Adresse | Rôle |
|---|---|---|
| WIN-DC01 | 192.168.50.10 | Windows Server 2025 — Active Directory `infraready.test`, DNS |
| OPS01 | 192.168.50.20 | Ubuntu 26.04 — Ansible, Prometheus, Grafana |
| LINUX01 | 192.168.50.30 | Ubuntu 26.04 — nginx, stockage `/srv/data` |

## Documentation

| Document | Contenu |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Schéma, rôles, choix techniques, écarts au sujet |
| [docs/adressage-ip.md](docs/adressage-ip.md) | Plan d'adressage, configuration réseau, matrice des flux |
| [docs/securite.md](docs/securite.md) | Mesures de sécurité, limites assumées, fonctionnalité non terminée |
| [docs/maintenance.md](docs/maintenance.md) | Procédure de maintenance et résultats |
| [docs/incident.md](docs/incident.md) | Rapport d'incident et incidents réels |

## Prérequis (sur OPS01)

```bash
sudo apt install -y ansible-core python3-winrm git
ansible-galaxy collection install -r collections/requirements.yml
```

- Clé SSH d'OPS01 copiée sur LINUX01 (`ssh-copy-id adminlinux@linux01.infraready.test`).
- WinRM HTTPS activé sur WIN-DC01 (port 5986, règle de pare-feu limitée à OPS01).
- Mot de passe du vault fourni par le binôme (jamais dans le dépôt).

## Utilisation

Toutes les commandes se lancent depuis la racine du dépôt, sur OPS01.

```bash
ansible-playbook playbooks/ping-all.yml --ask-vault-pass                      # joignabilité des 3 machines
ansible-playbook playbooks/linux/nginx.yml --ask-vault-pass                   # serveur web
ansible-playbook playbooks/linux/comptes-permissions.yml --ask-vault-pass     # comptes, groupes, sudo
ansible-playbook playbooks/linux/stockage.yml --ask-vault-pass -e data_disk=/dev/sdb
ansible-playbook playbooks/windows/ad-groupes-utilisateurs.yml --ask-vault-pass
ansible-playbook playbooks/monitoring.yml --ask-vault-pass                    # Prometheus, Grafana, exporters
ansible-playbook playbooks/pare-feu.yml --ask-vault-pass                      # ufw + pare-feu Windows
ansible-playbook playbooks/linux/maintenance.yml --ask-vault-pass             # rapport de maintenance Linux
ansible-playbook playbooks/windows/maintenance-windows.yml --ask-vault-pass   # rapport de maintenance Windows
```

Tous les playbooks sont idempotents : un second passage donne `changed=0` (sauf l'écriture des rapports de maintenance).

| Interface | Adresse |
|---|---|
| Grafana | http://192.168.50.20:3000 — tableau « InfraReady – Vue d'ensemble » |
| Prometheus | http://192.168.50.20:9090 — `/targets`, `/alerts` |
| Site nginx | http://linux01.infraready.test |

## Validation

```bash
bash scripts/ci/verifier-secrets.sh   # avant chaque commit
bash scripts/ci/valider-local.sh      # mêmes contrôles que la CI, rapport dans preuves/
```

Le workflow `.github/workflows/validation.yml` exécute ces contrôles à chaque push ; son exécution sur GitHub est actuellement bloquée par le compte (voir `docs/securite.md`).
