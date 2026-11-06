#!/usr/bin/env bash
# Rejoue en local les controles du workflow .github/workflows/validation.yml.
#
# Pourquoi : les runners GitHub Actions ne demarrent pas sur le compte proprietaire
# du depot ("account is locked", facturation). Le workflow est pret ; ce script
# fournit la meme validation et sa preuve en attendant.
#
# Usage (depuis la racine du depot, sur OPS01) :
#   bash scripts/ci/valider-local.sh
# Resultat : affichage + rapport dans preuves/G_validation_locale_<date>.txt
# Code retour : 0 si tous les controles executes reussissent, 1 sinon.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

horodatage=$(date +%Y-%m-%d_%H%M)
mkdir -p preuves
rapport="preuves/G_validation_locale_${horodatage}.txt"
exec > >(tee "$rapport") 2>&1

declare -a noms=() etats=()
echecs=0

controle() {   # controle "Nom" commande...
  local nom=$1; shift
  echo
  echo "────────────────────────────────────────────────────────────"
  echo "▶ $nom"
  echo "  \$ $*"
  echo "────────────────────────────────────────────────────────────"
  if "$@"; then
    noms+=("$nom"); etats+=("OK")
  else
    noms+=("$nom"); etats+=("ECHEC"); echecs=$((echecs + 1))
  fi
}

absent() {     # absent "Nom" outil "commande d'installation"
  noms+=("$1"); etats+=("NON EXECUTE (outil $2 absent : $3)")
}

syntaxe_playbooks() {
  local rc=0
  while IFS= read -r p; do
    if ansible-playbook --syntax-check "$p" >/dev/null 2>/tmp/syntaxe.err; then
      echo "  OK     $p"
    else
      echo "  ERREUR $p"; sed 's/^/         /' /tmp/syntaxe.err; rc=1
    fi
  done < <(find playbooks -name '*.yml' | sort)
  return "$rc"
}

dashboard_json() {
  python3 - <<'PY'
import json, glob, sys
ok = True
for f in sorted(glob.glob("monitoring/dashboards/*.json")):
    d = json.load(open(f))
    uids = {t["datasource"]["uid"] for p in d["panels"] for t in p.get("targets", [])}
    if uids != {"prometheus-infraready"}:
        print(f"  ERREUR {f}: source de donnees inattendue {uids}"); ok = False
    else:
        print(f"  OK     {f}: {len(d['panels'])} panneaux, JSON valide")
sys.exit(0 if ok else 1)
PY
}

echo "Validation locale InfraReady — $(date '+%Y-%m-%d %H:%M')"
echo "Commit : $(git log -1 --format='%h %s')"
echo "Hote   : $(hostname)"

# ---------------------------- Job "Ansible" ----------------------------- #
if command -v yamllint >/dev/null; then controle "Ansible : style YAML (yamllint)" yamllint .
else absent "Ansible : style YAML (yamllint)" yamllint "sudo apt install yamllint"; fi

if command -v ansible-lint >/dev/null; then controle "Ansible : bonnes pratiques (ansible-lint, profil production)" ansible-lint
else absent "Ansible : bonnes pratiques (ansible-lint)" ansible-lint "pipx install ansible-lint"; fi

controle "Ansible : syntaxe de chaque playbook" syntaxe_playbooks

# --------------------------- Job "Supervision" -------------------------- #
if command -v promtool >/dev/null; then
  controle "Supervision : configuration Prometheus" promtool check config monitoring/prometheus.yml
  controle "Supervision : regles d'alerte" promtool check rules monitoring/rules/infraready.yml
  controle "Supervision : tests unitaires des alertes" bash -c 'cd monitoring/rules && promtool test rules infraready_test.yml'
else
  absent "Supervision : promtool" promtool "sudo apt install prometheus"
fi
controle "Supervision : tableau de bord Grafana" dashboard_json

# ---------------------------- Job "Securite" ---------------------------- #
controle "Securite : vault chiffres, cles privees, mots de passe en clair" bash scripts/ci/verifier-secrets.sh

if command -v gitleaks >/dev/null; then
  if gitleaks help 2>/dev/null | grep -qE '^\s+git\b'; then   # gitleaks >= 8.19
    controle "Securite : secrets dans tout l'historique Git (gitleaks)" gitleaks git --redact --no-banner .
  else                                                          # versions plus anciennes
    controle "Securite : secrets dans tout l'historique Git (gitleaks)" gitleaks detect --source . --redact --no-banner
  fi
else
  absent "Securite : gitleaks" gitleaks "sudo apt install gitleaks"
fi

# --------------------------- Job "PowerShell" --------------------------- #
if command -v pwsh >/dev/null; then
  controle "PowerShell : syntaxe des scripts" pwsh -NoProfile -Command '
    $e = 0
    Get-ChildItem scripts -Recurse -Filter *.ps1 | ForEach-Object {
      $err = $null
      [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err) | Out-Null
      if ($err) { "  ERREUR $($_.Name) : $($err[0].Message)"; $e++ } else { "  OK     $($_.Name)" }
    }
    exit $e'
else
  absent "PowerShell : syntaxe des scripts" pwsh "non installe sur OPS01, controle effectue par la CI uniquement"
fi

# -------------------------------- Bilan --------------------------------- #
echo
echo "════════════════════════════ BILAN ════════════════════════════"
for i in "${!noms[@]}"; do
  printf '  %-62s %s\n' "${noms[$i]}" "${etats[$i]}"
done
echo "════════════════════════════════════════════════════════════════"
if [ "$echecs" -gt 0 ]; then
  echo "RESULTAT : $echecs controle(s) en ECHEC"
else
  echo "RESULTAT : tous les controles executes ont reussi"
fi
echo "Rapport : $rapport"
exit $((echecs > 0))
