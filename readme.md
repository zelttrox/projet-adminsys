# Automatisation d'infrastructure avec Ansible

Projet de lab pour automatiser la gestion d'un environnement mixte **Windows Server 2025** (contrôleur de domaine Active Directory) et **Ubuntu Server 24.04** depuis une machine de contrôle Linux **Ops**.

Ansible est **agentless** : rien n'est installé sur les serveurs cibles. Toutes les connexions passent par **SSH avec authentification par clé**, aussi bien vers Linux que vers Windows.

---

## Sommaire

- [Architecture](#architecture)
- [Arborescence](#arborescence)
- [Prérequis](#prérequis)
- [Configuration](#configuration)
- [Playbooks](#playbooks)
- [Utilisation](#utilisation)
- [Dépannage](#dépannage)
- [Évolutions prévues](#évolutions-prévues)

---

## Architecture

```
                    ┌──────────────────────────┐
                    │  ops01 (nœud de contrôle)│
                    │  Ansible + clé SSH       │
                    │  192.168.50.129          │
                    └────────────┬─────────────┘
                                 │ SSH (clé)
                ┌────────────────┴────────────────┐
                ▼                                 ▼
   ┌──────────────────────────┐      ┌──────────────────────────┐
   │ win-dc01                 │      │ linux01                  │
   │ Windows Server 2025      │      │ Ubuntu Server 24.04      │
   │ AD DS – infraready.test  │      │ Serveur web Nginx        │
   │ 192.168.50.10            │      │                          │
   └──────────────────────────┘      └──────────────────────────┘
```

| Hôte | Système | Rôle | Connexion |
|---|---|---|---|
| `ops01` | Linux | Nœud de contrôle Ansible | locale |
| `win-dc01` | Windows Server 2025 | Contrôleur de domaine `infraready.test` | SSH + PowerShell |
| `linux01` | Ubuntu Server 24.04 | Serveur web | SSH |

Les adresses IP et utilisateurs de référence sont dans [`inventory/hosts.ini`](inventory/hosts.ini).

---

## Arborescence

```
.
├── ansible.cfg                    # Configuration du projet (inventaire, clé SSH…)
├── inventory
│   └── hosts.ini                  # Liste des machines et variables de connexion
├── monitoring                     # Supervision (à venir)
├── playbooks
│   ├── linux
│   │   └── nginx.yml              # Installation et configuration de Nginx
│   ├── update_servers.yml         # Mises à jour Windows + Ubuntu
│   └── windows
│       └── add_users_groups.yml   # Création des groupes et utilisateurs AD
├── readme.md
├── roles                          # Rôles Ansible (à venir)
└── scripts
    └── users_groups.ps1           # Script PowerShell de création AD
```

---

## Prérequis

### Machine Ops (nœud de contrôle)

```bash
sudo apt install ansible            # ou : pipx install --include-deps ansible
ansible-galaxy collection install ansible.windows community.windows community.general
```

### Serveur Ubuntu

- OpenSSH Server (installé par défaut sur Ubuntu Server)
- Python 3 (présent par défaut sur Ubuntu 24.04)
- Un utilisateur avec les droits `sudo`

### Serveur Windows

- OpenSSH Server activé et démarré :
  ```powershell
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd
  ```
- Rôle **AD DS** installé et serveur promu contrôleur de domaine
- Un compte **administrateur du domaine** (`win-dc01@infraready.test`)

---

## Configuration

### 1. Clé SSH

Sur la machine Ops :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@ops01"
chmod 700 ~/.ssh && chmod 600 ~/.ssh/ansible
```

**Vers Linux :**

```bash
ssh-copy-id -i ~/.ssh/ansible.pub adminlinux@<ip_linux01>
```

**Vers Windows :** pour un compte administrateur, la clé publique va dans le fichier commun `C:\ProgramData\ssh\administrators_authorized_keys`. Dans un PowerShell administrateur :

```powershell
Add-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Value "<contenu de ansible.pub>" -Encoding utf8
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "*S-1-5-32-544:F" /grant "SYSTEM:F"
```

### 2. `ansible.cfg`

```ini
[defaults]
inventory = inventory/hosts.ini
private_key_file = ~/.ssh/ansible
host_key_checking = False
interpreter_python = auto_silent
```

> `host_key_checking = False` est acceptable en lab, mais à désactiver en production.

### 3. `inventory/hosts.ini`

```ini
[windows]
win-dc01 ansible_host=192.168.50.10 ansible_user=win-dc01@infraready.test

[linux]
linux01 ansible_host=<ip_linux01> ansible_user=adminlinux

[ops]
ops01 ansible_connection=local

[windows:vars]
ansible_connection=ssh
ansible_shell_type=powershell
```

### 4. Secrets (Ansible Vault)

Les mots de passe ne doivent pas être écrits en clair dans les playbooks. Pour chiffrer le mot de passe initial des comptes AD :

```bash
mkdir -p inventory/group_vars
ansible-vault encrypt_string 'MotDePasseInitial!2026' --name 'vault_default_password' > inventory/group_vars/windows.yml
```

### 5. Vérifier la connexion

```bash
ansible linux -m ping
ansible windows -m ansible.windows.win_ping
```

Chaque hôte doit répondre `"ping": "pong"`.

---

## Playbooks

### `playbooks/linux/nginx.yml` : serveur web Nginx

Cible : groupe `linux` (Ubuntu 24.04)

- Vérifie que la cible est bien une Ubuntu 24.04
- Installe Nginx et déploie un site dédié (`/var/www/monsite`)
- Désactive le site par défaut
- Ouvre le port 80 dans UFW
- Teste la configuration (`nginx -t`) avant chaque rechargement
- Vérifie à la fin que le site répond en HTTP 200

> Les templates `site.conf.j2` et `index.html.j2` doivent se trouver dans `playbooks/linux/templates/`.

### `playbooks/update_servers.yml` : mises à jour

Cible : groupes `windows` et `linux`

| | Windows Server | Ubuntu Server |
|---|---|---|
| Méthode | `win_updates` (sécurité, critiques, cumulatifs, définitions) | `apt dist-upgrade` + `autoremove` |
| Redémarrage | Automatique, autant de fois que nécessaire | Seulement si `/var/run/reboot-required` existe |

Variable : `allow_reboot` (`true` par défaut). Avec `-e allow_reboot=false`, les mises à jour sont installées sans redémarrage.

### `playbooks/windows/add_users_groups.yml` : utilisateurs et groupes AD

Cible : groupe `windows` (contrôleur de domaine)

Exécute [`scripts/users_groups.ps1`](scripts/users_groups.ps1), qui crée dans l'OU **Utilisateurs Lab** :

| Groupe | Utilisateurs |
|---|---|
| **Employés** | `claurent` (Camille Laurent), `hpetit` (Hugo Petit), `lgarnier` (Léa Garnier) |
| **IT** | `troux` (Thomas Roux), `ifontaine` (Inès Fontaine), `nmercier` (Nathan Mercier) |

Le script est **idempotent**, on peut donc le relancer sans risque :

- un groupe n'est créé que si aucun groupe ne porte déjà ce nom ;
- un utilisateur n'est créé que si son identifiant, son UPN et son nom complet sont libres ;
- un utilisateur n'est ajouté à un groupe que s'il n'en est pas déjà membre ;
- le script renvoie le code `1` en cas d'erreur, ce qui fait échouer la tâche Ansible.

Les comptes sont créés avec le mot de passe passé en paramètre (`-DefaultPassword`) et doivent le changer à la première connexion.

> Le script est encodé en **UTF-8 avec BOM**, ce qui est nécessaire pour que Windows PowerShell 5.1 lise correctement les accents. Conservez cet encodage si vous le modifiez.

---

## Utilisation

Toutes les commandes se lancent **depuis la racine du projet**, là où se trouve `ansible.cfg`.

```bash
# Serveur web
ansible-playbook playbooks/linux/nginx.yml --ask-become-pass

# Mises à jour de tous les serveurs
ansible-playbook playbooks/update_servers.yml --ask-become-pass

# Mises à jour d'un seul groupe, sans redémarrage
ansible-playbook playbooks/update_servers.yml --limit linux -e allow_reboot=false --ask-become-pass

# Utilisateurs et groupes AD
ansible-playbook playbooks/windows/add_users_groups.yml --ask-vault-pass
```

Options utiles :

| Option | Effet |
|---|---|
| `--check` | Simulation, sans rien modifier |
| `--diff` | Affiche les changements apportés aux fichiers |
| `--limit <hôte\|groupe>` | Restreint l'exécution à certaines machines |
| `-v` / `-vvv` | Augmente le niveau de détail des logs |

---

## Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Permission denied (publickey)` | Clé absente ou mal placée sur la cible | Vérifier `authorized_keys` (Linux) ou `administrators_authorized_keys` et ses permissions (Windows) |
| Ansible utilise WinRM au lieu de SSH | Anciennes variables dans `group_vars/windows.yml` | Supprimer `ansible_connection: winrm`, `ansible_port`, `ansible_winrm_*` |
| `Could not find or access 'scripts/users_groups.ps1'` | Chemin relatif résolu depuis `playbooks/windows/` | Utiliser `{{ playbook_dir }}/../../scripts/users_groups.ps1` |
| `Module ActiveDirectory indisponible` | AD DS non installé ou mauvaise machine ciblée | Lancer le script sur le contrôleur de domaine |
| Erreur AD (`Accès refusé`, serveur injoignable) alors que le script fonctionne en local | Session SSH par clé sans identifiants délégués | Ajouter `become: true` / `become_method: runas` sur la tâche |
| La tâche échoue sans message lisible | `no_log: true` masque aussi les erreurs | Le passer temporairement à `false` |
| Accents illisibles dans l'AD (`EmployÃ©s`) | Script ré-enregistré sans BOM | Ré-enregistrer en UTF-8 avec BOM |

---

## Évolutions prévues

- **`roles/`** : découper les playbooks en rôles réutilisables (`nginx`, `ad_users`, `updates`)
- **`monitoring/`** : déploiement d'une solution de supervision des serveurs
- Passage des utilisateurs AD dans un fichier de variables plutôt qu'en dur dans le script
- Modules natifs `microsoft.ad.user` / `microsoft.ad.group` en alternative au script PowerShell