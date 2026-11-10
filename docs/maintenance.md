# Procédure de maintenance et de mises à jour

Projet InfraReady — partie E. Ce document décrit **comment** on maintient les trois serveurs, **quelles précautions** on prend, et **ce qui s'est réellement passé** lors de la maintenance du 23/10/2026.

## 1. Principes

| Principe | Mise en œuvre |
|---|---|
| Ne jamais modifier sans pouvoir revenir en arrière | Snapshot VMware obligatoire : les playbooks refusent le mode `appliquer` sans `-e snapshot_ok=oui` |
| Ne pas mettre à jour un système déjà dégradé | Contrôles **avant** : espace disque sous le seuil, services critiques actifs. Échec = arrêt avant toute modification |
| Voir avant d'agir | Mode `rapport` par défaut : liste des mises à jour, aucune installation |
| Une machine à la fois | `serial: 1` côté Linux : un échec n'atteint pas les machines suivantes |
| Redémarrer seulement si nécessaire et autorisé | Redémarrage uniquement si le système le demande **et** `-e autoriser_reboot=true` |
| Ne jamais scier la branche sur laquelle on est assis | OPS01 (contrôleur Ansible) n'est jamais redémarré par Ansible ; les paquets d'Ansible sont protégés |
| Prouver le résultat | Contrôles **après** + rapport daté dans `preuves/E_maintenance_<hôte>_<date>.txt` |

## 2. Outils

| Fichier | Rôle |
|---|---|
| `playbooks/linux/maintenance.yml` | LINUX01 et OPS01 : apt, contrôles, rapport |
| `playbooks/windows/maintenance-windows.yml` | WIN-DC01 : agent Windows Update natif via `ansible.windows.win_updates` |
| `playbooks/ping-all.yml` | Vérification de la joignabilité des trois machines avant et après |

Secrets : mots de passe sudo et Windows dans Ansible Vault (`inventory/group_vars/*/vault.yml`), déverrouillés par `--ask-vault-pass`.

## 3. Procédure pas à pas

### 3.1 Préparation

1. Vérifier que les trois machines répondent :
   `ansible-playbook playbooks/ping-all.yml --ask-vault-pass`
2. Lancer les rapports, sans aucune modification :
   ```bash
   ansible-playbook playbooks/linux/maintenance.yml --ask-vault-pass
   ansible-playbook playbooks/windows/maintenance-windows.yml --ask-vault-pass
   ```
3. Lire les rapports dans `preuves/` : nombre de mises à jour, paquets supprimés, mises à jour différées, redémarrage prévisible.
4. Prévenir les utilisateurs si WIN-DC01 doit redémarrer (coupure AD **et** DNS du labo).

### 3.2 Linux — ordre : LINUX01, puis OPS01

```bash
# Snapshot VMware de LINUX01, puis :
ansible-playbook playbooks/linux/maintenance.yml --ask-vault-pass --limit linux01 \
  -e mode=appliquer -e snapshot_ok=oui -e autoriser_reboot=true

# Snapshot VMware d'OPS01, puis :
ansible-playbook playbooks/linux/maintenance.yml --ask-vault-pass --limit ops01 \
  -e mode=appliquer -e snapshot_ok=oui
# Si "Redemarrage requis : OUI" : sudo reboot à la main sur OPS01
```

Le serveur applicatif passe **avant** le contrôleur : si une mise à jour pose problème sur LINUX01, OPS01 est toujours intact pour diagnostiquer.

### 3.3 Windows — WIN-DC01

```bash
# Snapshot VMware de WIN-DC01, puis :
ansible-playbook playbooks/windows/maintenance-windows.yml --ask-vault-pass \
  -e mode=appliquer -e snapshot_ok=oui -e autoriser_reboot=true
```

- Catégories installées : `SecurityUpdates`, `CriticalUpdates`, `UpdateRollups`. Pas de mise à niveau de version.
- Mécanisme natif : le module pilote l'agent Windows Update du serveur, comme `sconfig` → option *Mettre à jour Windows* ou *Paramètres → Windows Update*. La procédure manuelle équivalente reste possible en cas de panne d'Ansible.
- Après redémarrage, le playbook attend qu'Active Directory réponde (jusqu'à 5 minutes), puis vérifie NTDS, DNS, Netlogon, ADWS, KDC, W32Time, WinRM et la résolution de `infraready.test`.

### 3.4 Après la maintenance

1. `ansible-playbook playbooks/ping-all.yml --ask-vault-pass`
2. Relancer les deux playbooks en mode `rapport` : 0 mise à jour attendue (hors mises à jour différées par Ubuntu).
3. `curl -I http://linux01.infraready.test` : HTTP 200.
4. Noter l'intervention dans le journal de changements et conserver les rapports dans `preuves/`.
5. Supprimer les snapshots de plus de quelques jours une fois le bon fonctionnement confirmé (un snapshot n'est pas une sauvegarde et ralentit la VM).

## 4. Contrôles automatiques

| Contrôle | Seuil / attendu | Avant | Après | Échec |
|---|---|:---:|:---:|---|
| Espace disque Linux (ext4/xfs/btrfs) | < 85 % utilisé | ✔ | | Arrêt |
| Espace libre C: | ≥ 10 Go | ✔ | | Arrêt |
| Services LINUX01 | ssh, nginx `running` | ✔ | ✔ | Arrêt |
| Services OPS01 | ssh `running` | ✔ | ✔ | Arrêt |
| Services WIN-DC01 | NTDS, DNS, Netlogon, ADWS, KDC, W32Time, WinRM `Running` | ✔ | ✔ | Arrêt |
| Paquets protégés | `ansible-core`, `python3-winrm`, `openssh-server`, `nginx`, `sudo` jamais supprimés | ✔ (simulation `apt-get -s`) | | Arrêt avant installation |
| DNS du domaine | `infraready.test` résout sur WIN-DC01 | | ✔ | Échec signalé |
| Redémarrage requis | `/var/run/reboot-required`, clé `RebootRequired` Windows | | ✔ | Indiqué dans le rapport |

## 5. Précautions avant redémarrage ou changement majeur

1. **Snapshot** de la VM concernée, nommé par date et objet (`06-pre-maj`). Vérifier qu'il apparaît dans le *Snapshot Manager*.
2. **Repérer les paquets sensibles** dans le rapport : `systemd`, `netplan.io`, `cloud-init`, `openssh-server`, noyau. Ils touchent au réseau, au démarrage ou à l'accès distant.
3. **Vérifier que la configuration réseau survivra au redémarrage** : `cloud-init` ne doit pas gérer le réseau (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` présent), sinon le DNS repasse sur la passerelle NAT.
4. **Garder un accès console** (VMware) en plus de SSH/WinRM : si le réseau tombe, c'est le seul chemin.
5. **WIN-DC01 en dernier, et seul** : unique contrôleur de domaine et unique DNS du labo. Pendant son redémarrage, les noms `*.infraready.test` ne résolvent plus.
6. **Jamais OPS01 par Ansible** : le contrôleur se couperait lui-même en pleine exécution.
7. **Ordre de retour arrière** : restaurer le snapshot, puis relancer le mode rapport pour confirmer l'état.

## 6. Résultats du 23/10/2026

### LINUX01 (Ubuntu 26.04, noyau 7.0.0-38)

| Étape | Résultat |
|---|---|
| Rapport initial | 41 mises à jour ; `/` 47,1 %, `/boot` 11,2 %, `/srv/data` 5,3 % ; ssh et nginx `running` |
| Application | 41 paquets mis à jour, aucun redémarrage requis, services `running` |
| Vérification DNS après | `win-dc01.infraready.test` → 192.168.50.10 |
| Rapport final | **0** mise à jour disponible |

### OPS01 (Ubuntu 26.04, noyau 7.0.0-38)

| Étape | Résultat |
|---|---|
| Rapport initial | 48 mises à jour ; `/` 38,4 %, `/boot` 11,2 % ; ssh `running` |
| Application | 44 paquets mis à jour, 4 supprimés dont **`ansible-core`** → incident, voir §7 |
| Mises à jour différées | `cloud-init`, `cloud-init-base`, `ubuntu-pro-client`, `ubuntu-pro-client-l10n` (phased updates, voir §8) |
| Après correction | Ansible réinstallé, redémarrage manuel, 3 machines joignables |
| Rapport final | 4 mises à jour restantes = les mises à jour différées par Ubuntu |

### WIN-DC01 (Windows Server 2025)

| Étape | Résultat |
|---|---|
| Rapport initial (23/10, 16:27) | Build 26100.32230 ; C: 28,8 Go libres / 48,3 Go ; 7 services AD/DNS `Running` ; 3 mises à jour : KB5126646 (cumulative de sécurité), KB5127690 (.NET), KB890830 (MSRT) |
| Installation | KB5126646, KB5127690 et KB5126645 installées le 23/10 à 16:52 (historique `Get-HotFix` et journal *WindowsUpdateClient*, événement 19). Origine : _passage `appliquer` du playbook ou Windows Update automatique — à confirmer avec `C:\Windows\Temp\infraready-win_updates.log`_ |
| Passage `appliquer` du 05/11 | 0 mise à jour trouvée, build **26100.33650**, services et DNS du domaine OK, aucun redémarrage en attente |
| Constat | Windows Update installe aussi seul des mises à jour (Defender, Windows App Runtime le 05/11). Sur un contrôleur de domaine, des installations automatiques peuvent entraîner un redémarrage non planifié, donc une coupure AD/DNS. Recommandation : stratégie Windows Update « télécharger et notifier » pour que l'installation reste déclenchée par la procédure |

## 7. Incident : le contrôleur Ansible s'est supprimé lui-même

| | |
|---|---|
| **Symptôme** | Le playbook échoue sur OPS01 avec `Module result deserialization failed: Unknown profile name 'module_legacy_m2c'`, puis la commande `ansible` est introuvable |
| **Diagnostic** | La sortie d'apt dans l'erreur : `The following packages will be REMOVED: ansible-core python3-nacl python3-paramiko python3-resolvelib` |
| **Cause** | `ansible-core` avait été installé comme **dépendance** du paquet `ansible`, retiré ensuite. apt le considérait comme orphelin ; l'option `autoremove: true` l'a supprimé pendant que le playbook tournait. Le module a fini son travail, mais Ansible ne pouvait plus lire son résultat |
| **Impact** | Mises à jour bien installées ; Ansible indisponible sur OPS01. LINUX01 et WIN-DC01 non touchés |
| **Correction** | `sudo apt install ansible-core` (le marque comme installé manuellement), vérification par `apt-mark showmanual`, collections intactes dans `~/.ansible/collections` |
| **Prévention** | Le playbook marque désormais les paquets critiques comme manuels, **simule** la mise à jour (`apt-get -s`) et **refuse de continuer** si un paquet protégé serait supprimé. Test effectué sur la sortie réelle de l'incident : la suppression d'`ansible-core` est détectée et bloquée |
| **Leçon** | Un outil d'administration doit protéger son propre environnement ; le contrôleur est une machine à part, à traiter en dernier et avec plus de précautions |

## 8. Points notables

- **Mises à jour progressives (phased updates)** : Ubuntu distribue certaines mises à jour à un pourcentage croissant de machines. apt les retient volontairement (« deferred due to phasing »). Elles ne sont pas en échec ; elles seront appliquées lors d'une maintenance ultérieure.
- **Version d'Ubuntu** : les VM sont en 26.04 « Resolute » et non en 24.04 comme prévu par le sujet. Conséquences gérées : sudo-rs par défaut (Ansible passe par `sudo.ws`), Python 3.14, `ansible-core` seul dans le PPA (collections installées via `collections/requirements.yml`).
- **Fuseau horaire** : les serveurs Linux étaient en UTC ; le playbook les aligne sur Europe/Paris pour corréler les journaux avec WIN-DC01. Les horodatages ISO 8601 des rapports restent en UTC (suffixe `Z`).
- **Redémarrages de services reportés** : après une mise à jour de `systemd` ou `dbus`, `needrestart` peut reporter des redémarrages. Un redémarrage planifié de la machine les finalise.
