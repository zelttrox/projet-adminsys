# Rapport d'incident

Projet InfraReady — partie H. Un incident simple, contrôlé et réversible, diagnostiqué selon la méthode du sujet : symptôme → tests et journaux → cause → correction → vérification. L'annexe reprend trois incidents **réels** rencontrés pendant le projet.

## Incident principal : absence de métriques de LINUX01

| | |
|---|---|
| **Date** | 06/11/2026 |
| **Type** | Absence de métriques d'un hôte (exemple du sujet) |
| **Nature** | Incident **injecté volontairement**, réalisé en solo : la panne a été provoquée puis diagnostiquée en suivant la démarche complète, sans raccourci par la cause connue |
| **Machines** | LINUX01 (cible), OPS01 (supervision), WIN-DC01 non concerné |
| **Gravité** | Moyenne : aucun service rendu aux utilisateurs n'est interrompu, mais LINUX01 n'est plus supervisé (une vraie panne passerait inaperçue) |

### Injection (pour mémoire)

Depuis OPS01, suppression de la règle ufw qui autorise Prometheus à lire `node_exporter`, puis redémarrage de l'exporter :

```bash
ansible linux01 -m community.general.ufw -a "rule=allow proto=tcp port=9100 from_ip=192.168.50.20 delete=true" --become --ask-vault-pass
ansible linux01 -m ansible.builtin.service -a "name=prometheus-node-exporter state=restarted" --become --ask-vault-pass
```

Le redémarrage est nécessaire pour que la panne apparaisse : ufw laisse passer les connexions **déjà établies** (suivi de connexion `ESTABLISHED,RELATED`), et Prometheus réutilise une connexion HTTP persistante. Sans redémarrage, la suppression de la règle n'aurait eu **aucun effet visible** — jusqu'au prochain redémarrage de l'exporter ou de la machine, où la panne serait apparue sans lien apparent avec la modification. C'est un piège réel des modifications de pare-feu.

### 1. Symptôme observé

- Grafana, panneau *Disponibilité des serveurs* : **linux01 HORS LIGNE**, ops01 et win-dc01 EN LIGNE.
- Prometheus `/targets` : cible `192.168.50.30:9100` (job `linux`) **DOWN**, erreur de délai dépassé.
- Prometheus `/alerts` : `HoteInjoignable` (sévérité critique) en *Pending* puis *Firing* après 1 minute.
- Panneaux CPU, mémoire et disque : plus aucune donnée pour linux01.

> Captures : `preuves/H_symptome_grafana.png`, `preuves/H_symptome_alerte.png`, `preuves/H_symptome_targets.png`

**Piège du symptôme** : « hors ligne » suggère une machine arrêtée. Rien ne permet encore de le dire — `up == 0` signifie seulement que Prometheus n'a pas pu lire l'exporter.

### 2. Tests et journaux consultés

Démarche par couches, de la plus basse à la plus haute, depuis OPS01. Chaque test élimine une hypothèse.

| # | Hypothèse testée | Commande | Résultat | Conclusion |
|---|---|---|---|---|
| a | Machine éteinte / réseau coupé | `ping -c2 192.168.50.30` | 2/2 reçus, 0 % de perte, ~0,5 ms | Machine allumée, réseau OK |
| b | Services applicatifs en panne | `curl -sI http://linux01.infraready.test` | `HTTP/1.1 200 OK` | nginx et DNS OK — les utilisateurs ne voient rien |
| c | Accès d'administration perdu | `ansible linux01 -m ping` | `SUCCESS`, `pong` | SSH et Ansible OK |
| d | Exporter arrêté | `systemctl is-active prometheus-node-exporter` | `active` | Le service tourne |
| e | Exporter défaillant | `curl -s -o /dev/null -w '%{http_code}' http://localhost:9100/metrics` (sur LINUX01) | `200` | L'exporter répond **localement** |
| f | Flux bloqué entre OPS01 et LINUX01 | `nc -zv -w 5 192.168.50.30 9100` (depuis OPS01) | `timed out` | **Quelque chose filtre entre les deux machines** |
| g | Règle de pare-feu manquante | `ufw status numbered` (sur LINUX01) | Règles `22/tcp` et `80/tcp` seulement — **plus de règle `9100/tcp`** | Cause trouvée |
| h | Confirmation par les journaux | `journalctl -k --since '-15 min' \| grep 'UFW BLOCK' \| grep 'DPT=9100'` | voir ci-dessous | Preuve des paquets rejetés |
| i | Origine de la modification | `journalctl -t sudo \| grep AnsiballZ_ufw` | Exécutions du module `ufw` par `adminops` via Ansible, horodatées (relevé effectué sur OPS01 : il couvre les passages de correction de 20:28-20:29 ; la trace de l'injection se lit de la même façon dans le journal de LINUX01) | La configuration du pare-feu est modifiée uniquement par Ansible, avec un compte nominatif : chaque modification est datée et attribuée |

Extrait du journal noyau (test h) :

```
nov. 06 20:24:51 linux01 kernel: [UFW BLOCK] IN=ens33 SRC=192.168.50.20 DST=192.168.50.30 ... PROTO=TCP SPT=55448 DPT=9100 ... SYN
nov. 06 20:25:11 linux01 kernel: [UFW BLOCK] IN=ens33 SRC=192.168.50.20 DST=192.168.50.30 ... PROTO=TCP SPT=33804 DPT=9100 ... SYN
nov. 06 20:25:32 linux01 kernel: [UFW BLOCK] IN=ens33 SRC=192.168.50.20 DST=192.168.50.30 ... PROTO=TCP SPT=46704 DPT=9100 ... SYN
```

Lecture : OPS01 (`SRC=192.168.50.20`) tente d'ouvrir (`SYN`) une connexion vers le port 9100 de LINUX01 ; ufw la rejette. Une tentative toutes les ~20 s : le rythme des relevés de Prometheus (15 s) plus le délai d'expiration. Le rejet est **silencieux** (politique `deny` = paquet jeté), ce qui explique le `timed out` du test f plutôt qu'un `connection refused`.

Ces journaux existent parce que la journalisation ufw a été activée (`logging: low`) par le playbook `pare-feu.yml`.

### 3. Cause identifiée

La règle ufw `9100/tcp ALLOW IN 192.168.50.20` avait été supprimée sur LINUX01. Prometheus (OPS01) ne pouvait plus ouvrir de connexion vers `node_exporter` ; la politique par défaut `deny (incoming)` s'appliquait. La machine et tous ses services fonctionnaient normalement — seul le flux de supervision était coupé.

Cause racine : modification manuelle de la configuration de pare-feu, hors du playbook qui en est la référence (dérive de configuration).

### 4. Correction appliquée

Pas de correction manuelle : réapplication de l'état de référence avec le playbook, qui ne modifie que ce qui a dérivé.

```bash
ansible-playbook playbooks/pare-feu.yml --ask-vault-pass
```

Résultat : la règle `9100/tcp` est recréée sur LINUX01 (`changed` sur la tâche « Autoriser les flux nécessaires »), rien n'est modifié ailleurs. Les vérifications intégrées au playbook passent (site nginx, cibles Prometheus, flux non prévus toujours refusés).

### 5. Vérification du retour à la normale

| Contrôle | Résultat |
|---|---|
| `nc -zv -w 5 192.168.50.30 9100` depuis OPS01 | `Connection to 192.168.50.30 9100 port [tcp/*] succeeded!` |
| Prometheus `/targets` | 4 cibles UP |
| Prometheus `/alerts` | `HoteInjoignable` résolue, 0 alerte active |
| Grafana | linux01 EN LIGNE, métriques de nouveau tracées |
| Second passage de `pare-feu.yml` | **`changed=0`** sur linux01, ops01 et win-dc01, `failed=0` : configuration conforme |

> Captures : `preuves/H_retour_grafana.png`, `preuves/H_retour_targets.png`

### Chronologie

| Heure | Événement |
|---|---|
| ~20:24 | Injection : suppression de la règle ufw et redémarrage de l'exporter |
| 20:24:51 | Premier paquet rejeté journalisé par ufw |
| ~20:25 | Cible DOWN dans Prometheus, linux01 HORS LIGNE dans Grafana |
| ~20:26 | Alerte `HoteInjoignable` en *Firing* (délai `for: 1m`) |
| 20:26–20:28 | Diagnostic par couches (tests a à h) |
| ~20:30 | Correction par `pare-feu.yml` |
| 20:31 | Second passage : `changed=0`, retour à la normale confirmé |

Détection en **~1 minute** après la panne (alerte automatique), résolution en **~6 minutes**.

### Enseignements

1. **Le symptôme trompe** : « hors ligne » ne veut pas dire « éteint ». Tester couche par couche évite de redémarrer une machine qui fonctionne.
2. **Tester localement puis à distance** (tests e et f) isole immédiatement un problème réseau ou pare-feu.
3. **Une modification de pare-feu peut avoir un effet différé** à cause des connexions établies : il faut la tester sur une nouvelle connexion.
4. **Le playbook est la référence** : il corrige la dérive en une commande et le second passage prouve la conformité.
5. **La journalisation paie** : sans `logging: low`, le test h n'aurait rien montré ; sans la journalisation de sudo, l'origine (test i) serait inconnue.

---

## Annexe : incidents réels rencontrés pendant le projet

Ces incidents n'ont pas été provoqués ; ils sont survenus pendant la réalisation et ont été diagnostiqués avec la même démarche.

### A1. Le contrôleur Ansible s'est supprimé lui-même (23/10, OPS01)

| | |
|---|---|
| **Symptôme** | Le playbook de maintenance échoue sur OPS01 : `Module result deserialization failed: Unknown profile name 'module_legacy_m2c'`, puis la commande `ansible` est introuvable |
| **Tests / journaux** | Sortie d'apt contenue dans l'erreur : `The following packages will be REMOVED: ansible-core python3-nacl python3-paramiko python3-resolvelib` ; `dpkg -l \| grep ansible` |
| **Cause** | `ansible-core` était marqué comme dépendance automatique (le paquet `ansible` qui l'avait installé avait été retiré). L'option `autoremove: true` l'a supprimé pendant l'exécution du playbook sur le contrôleur lui-même |
| **Correction** | `sudo apt install ansible-core` (le marque comme installé manuellement), vérifié par `apt-mark showmanual` |
| **Vérification** | `ansible --version`, collections intactes, 3 hôtes joignables |
| **Prévention** | Le playbook de maintenance marque les paquets critiques comme manuels, simule la mise à jour (`apt-get -s`) et refuse de continuer si un paquet protégé serait supprimé — testé sur la sortie réelle de l'incident. Détails : `docs/maintenance.md` §7 |

### A2. Faux arrêt de nginx pendant un test de délégation sudo (23/10, LINUX01)

| | |
|---|---|
| **Symptôme** | nginx arrêté (`ps` vide, rien sur le port 80) juste après avoir testé les droits sudo du compte `support1`, censé ne **pas** pouvoir arrêter nginx |
| **Tests / journaux** | `systemctl status nginx` (arrêt propre, `status=0/SUCCESS`, pas de plantage) ; `journalctl -u nginx -b` (arrêt demandé à 09:19:52 UTC) ; `journalctl \| grep -i sudo` |
| **Cause** | Le journal sudo montre `session closed for user support1` **avant** les commandes, puis `adminlinux : COMMAND=/usr/bin/systemctl stop nginx`. Le bloc de commandes avait été collé d'un coup : le shell `support1` s'était refermé et les tests ont été exécutés par `adminlinux`, qui a tous les droits. La délégation n'était pas en cause |
| **Correction** | `sudo systemctl start nginx` ; test refait sans shell interactif : `sudo -u support1 sudo -n systemctl …` |
| **Vérification** | `restart` autorisé (code 0), `stop` et `cat /etc/shadow` refusés (code 1), nginx `active` |
| **Enseignement** | Le journal sudo a permis de trancher entre « délégation trop large » (faille) et « erreur de manipulation ». Limite relevée : sudo-rs ne journalise pas les refus (voir `docs/securite.md`) |

### A3. Ansible bloqué à l'élévation de privilèges (22/10, LINUX01)

| | |
|---|---|
| **Symptôme** | Tout playbook avec `become: true` échoue : `Timeout (12s) waiting for privilege escalation prompt` |
| **Tests / journaux** | SSH par clé fonctionnel (le module se lance) ; invite observée `[sudo: authenticate] Password:` ; `sudo --version` ; `/etc/os-release` |
| **Cause** | Les VM sont en Ubuntu 26.04, qui utilise **sudo-rs** par défaut. Son invite de mot de passe diffère de celle de sudo classique, qu'Ansible attend pour envoyer le mot de passe |
| **Correction** | `ansible_become_exe=sudo.ws` dans l'inventaire (utilise le sudo classique, toujours installé) |
| **Vérification** | Playbook nginx : `ok=3 changed=1 failed=0` |
| **Enseignement** | Écart de version par rapport au sujet (24.04 prévue) : documenté, avec sa conséquence et son contournement |
