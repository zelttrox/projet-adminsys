# Sécurité et limites connues

## Mesures en place

### Secrets

| Mesure | Détail |
|---|---|
| Ansible Vault | `inventory/group_vars/{linux,ops,windows}/vault.yml` chiffrés en AES-256 : mots de passe sudo, mot de passe du compte Windows, mot de passe initial des comptes AD, mot de passe admin Grafana |
| Un seul mot de passe de vault, fort, hors dépôt | Conservé dans un gestionnaire de mots de passe ; jamais identique à un mot de passe qu'il protège |
| Aucun secret dans les fichiers versionnés | Les variables pointent vers le vault : `ansible_password: "{{ vault_windows_password }}"` |
| Contrôle automatique | `scripts/ci/verifier-secrets.sh` : vault chiffrés, absence de clé privée et de mot de passe en clair ; `gitleaks` sur tout l'historique (9 commits analysés, aucune fuite) |
| `no_log: true` | Sur les tâches qui manipulent un mot de passe (création des comptes AD, Grafana) |

### Accès et moindre privilège

| Élément | Mise en œuvre |
|---|---|
| SSH | Par clé ed25519 depuis OPS01 ; ufw limite le port 22 au réseau du labo |
| Comptes Linux de service | `webdev1`, `webdev2`, `support1` : mot de passe verrouillé, `/home` en 750 |
| Dossier web | `/var/www/infraready` en `root:webadmins` 2775 (setgid) : écriture pour `webadmins` seulement |
| Délégation sudo | Groupe `support` : `systemctl status nginx` et `systemctl restart nginx` uniquement. Fichier validé par `visudo` avant écriture. Testé : `restart` autorisé, `stop` et `cat /etc/shadow` refusés |
| Comptes AD | 6 comptes dans l'OU `InfraReady/Utilisateurs`, mot de passe initial à changer à la première connexion |
| WinRM | HTTPS (5986), règle de pare-feu limitée à OPS01 |
| Exporters | 9100 et 9182 accessibles **uniquement** depuis OPS01 ; flux non prévus testés et refusés |

### Pare-feu

- **Linux (ufw)** : entrée refusée par défaut, sortie autorisée, journalisation des refus (`logging low`). Matrice des flux : `docs/adressage-ip.md`.
- **Windows** : profil **Domaine** activé — il était désactivé alors que le réseau est en *DomainAuthenticated*, le contrôleur était donc sans pare-feu effectif.
- Appliqué et vérifié par `playbooks/pare-feu.yml` (idempotent : second passage `changed=0`).

### Exploitation

- Snapshot VMware avant tout changement important ; les playbooks de maintenance refusent le mode `appliquer` sans confirmation.
- Garde-fous : formatage refusé sur un disque non vide ; mise à jour refusée si elle supprimerait un paquet protégé ; jamais de redémarrage du contrôleur Ansible par lui-même.
- Traçabilité : journal sudo, journaux de sécurité Windows (4720, 4727, 4728), rapports datés dans `preuves/`.

## Limites assumées

| Limite | Risque | Ce qui permettrait de la lever |
|---|---|---|
| **Certificat WinRM auto-signé**, validation désactivée (`ansible_winrm_server_cert_validation=ignore`) | Interception possible par un poste du même réseau se faisant passer pour WIN-DC01 | Certificat émis par une AC interne (AD CS) et validation activée |
| **Authentification NTLM** pour WinRM | Protocole plus ancien que Kerberos | Kerberos (`ansible_winrm_transport=kerberos`) avec OPS01 intégré au domaine |
| **Ansible utilise un compte administrateur du domaine** | Compromission d'OPS01 = compromission du domaine | Compte de service dédié, délégation limitée aux OU gérées |
| **Clé SSH sans phrase de passe** sur OPS01 | Vol de la clé si OPS01 est compromis | Phrase de passe + `ssh-agent`, ou certificats SSH |
| **sudo-rs ne journalise pas les refus** | Tentatives d'élévation refusées invisibles dans le journal | Journalisation via auditd, ou sudo classique |
| **Grafana et Prometheus en HTTP** | Mot de passe Grafana en clair sur le réseau du labo | Reverse proxy TLS devant les deux services |
| **Mises à jour automatiques Windows actives** | Redémarrage non planifié du contrôleur (coupure AD/DNS) | Stratégie « télécharger et notifier » |
| **GitHub Actions non exécuté** | Pas de validation automatique côté GitHub | Voir ci-dessous |

## Fonctionnalité non terminée : exécution de GitHub Actions

Le workflow `.github/workflows/validation.yml` est écrit et validé syntaxiquement (actionlint). Il exécute à chaque push et pull request : yamllint, ansible-lint (profil production), syntaxe des playbooks ; promtool (configuration, règles, tests unitaires) ; contrôle des secrets et gitleaks ; analyse des scripts PowerShell.

**Blocage** : GitHub refuse de démarrer les runners — « *The job was not started because your account is locked* ». Le compte propriétaire du dépôt ne bénéficie plus de l'offre éducation et le binôme a choisi de ne pas y associer de moyen de paiement.

**Contournement** : les mêmes contrôles sont rejoués sur OPS01 par `scripts/ci/valider-local.sh` ; les rapports sont archivés dans `preuves/G_validation_locale_*.txt` (premier passage en échec sur deux défauts de style réels, dernier passage entièrement réussi).

**Pour finaliser** : réactiver GitHub Actions sur le compte (offre éducation ou facturation), puis *Re-run jobs*. Aucune modification du workflow n'est nécessaire.
