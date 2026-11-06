#!/usr/bin/env bash
# Controle de securite execute par la CI (et utilisable en local avant un commit).
#  1. tout fichier vault.yml doit etre chiffre par Ansible Vault ;
#  2. aucun fichier suivi par Git ne doit contenir de cle privee ;
#  3. aucune variable "password" ne doit avoir de valeur en clair hors du vault.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
erreurs=0

echo "== 1. Fichiers vault chiffres"
while IFS= read -r f; do
  if head -n1 "$f" | grep -q '^\$ANSIBLE_VAULT;'; then
    echo "  OK      $f"
  else
    echo "  ERREUR  $f n'est PAS chiffre (ansible-vault encrypt $f)"
    erreurs=$((erreurs + 1))
  fi
done < <(git ls-files '*vault.yml' '*vault.yaml')

echo "== 2. Cles privees"
if git grep -nI -E -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- . ':!scripts/ci/verifier-secrets.sh'; then
  echo "  ERREUR  cle privee trouvee ci-dessus"
  erreurs=$((erreurs + 1))
else
  echo "  OK      aucune cle privee"
fi

echo "== 3. Mots de passe en clair dans les variables"
# Accepte : references a une variable ("{{ vault_... }}", ${{ secrets.X }}), booleens, exemples CHANGE_ME
motif='^[[:space:]]*[A-Za-z0-9_]*(password|passwd|secret|token)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'{$[:space:]]'
if git grep -nI -i -E "$motif" -- '*.yml' '*.yaml' '*.ini' '*.cfg' ':!*vault.yml' ':!*.example' \
     | grep -v -i 'CHANGE_ME' \
     | grep -v -i -E ':[[:space:]]*(true|false|yes|no)[[:space:]]*(#.*)?$'; then
  echo "  ERREUR  valeur en clair ci-dessus : la deplacer dans un vault.yml"
  erreurs=$((erreurs + 1))
else
  echo "  OK      aucune valeur en clair"
fi

if [ "$erreurs" -gt 0 ]; then
  echo "ECHEC : $erreurs probleme(s) de secrets"
  exit 1
fi
echo "Controle des secrets reussi"
