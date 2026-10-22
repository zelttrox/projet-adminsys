<#
.SYNOPSIS
    Crée les groupes AD "Employés" et "IT" avec 3 utilisateurs dans chacun.

.DESCRIPTION
    Script idempotent : il peut être relancé autant de fois que nécessaire.
    - Un groupe n'est créé que s'il n'existe pas déjà (vérif. par Name et SamAccountName)
    - Un utilisateur n'est créé que s'il n'existe pas déjà (vérif. par SamAccountName, UPN et Name)
    - Un utilisateur n'est ajouté à un groupe que s'il n'en est pas déjà membre
    - Toute erreur est remontée, et le script se termine avec le code 1 en cas d'échec
      (une tâche Ansible échouera donc correctement)

.PARAMETER DefaultPassword
    Mot de passe initial des nouveaux comptes (changement obligatoire à la 1re connexion).

.PARAMETER OUName
    OU de destination, créée à la racine du domaine si elle n'existe pas.

.EXAMPLE
    .\users_groups.ps1 -DefaultPassword 'Ch@ngeMe!2026'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DefaultPassword,

    [string]$OUName = "Utilisateurs Lab"
)

$ErrorActionPreference = 'Stop'

# ─── Données ────────────────────────────────────────────────────────────────
# SamAccountName sans accents pour éviter les soucis de compatibilité
$groupes = @(
    @{ Name = "Employés"; Sam = "Employes"; Description = "Ensemble des employés" },
    @{ Name = "IT";       Sam = "IT";       Description = "Service informatique" }
)

$utilisateurs = @(
    # Groupe Employés
    @{ Sam = "claurent";  Prenom = "Camille"; Nom = "Laurent";  Groupe = "Employes"; Service = "Comptabilité" },
    @{ Sam = "hpetit";    Prenom = "Hugo";    Nom = "Petit";    Groupe = "Employes"; Service = "Commercial" },
    @{ Sam = "lgarnier";  Prenom = "Léa";     Nom = "Garnier";  Groupe = "Employes"; Service = "Ressources humaines" },
    # Groupe IT
    @{ Sam = "troux";     Prenom = "Thomas";  Nom = "Roux";     Groupe = "IT";       Service = "Informatique" },
    @{ Sam = "ifontaine"; Prenom = "Inès";    Nom = "Fontaine"; Groupe = "IT";       Service = "Informatique" },
    @{ Sam = "nmercier";  Prenom = "Nathan";  Nom = "Mercier";  Groupe = "IT";       Service = "Informatique" }
)

# ─── Compteurs ──────────────────────────────────────────────────────────────
$stats = [ordered]@{
    GroupesCrees       = 0
    GroupesExistants   = 0
    UsersCrees         = 0
    UsersExistants     = 0
    AjoutsGroupe       = 0
    Erreurs            = 0
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','SKIP','ERREUR')][string]$Level = 'INFO')
    Write-Output ("[{0}] {1}" -f $Level, $Message)
}

# ─── Prérequis ──────────────────────────────────────────────────────────────
try {
    Import-Module ActiveDirectory
    $domaine = Get-ADDomain
}
catch {
    Write-Log "Module ActiveDirectory indisponible ou domaine injoignable : $($_.Exception.Message)" 'ERREUR'
    exit 1
}

$securePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force
$ouPath = "OU=$OUName,$($domaine.DistinguishedName)"
Write-Log "Domaine : $($domaine.DNSRoot) | OU cible : $ouPath"

# ─── OU ─────────────────────────────────────────────────────────────────────
try {
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'") {
        Write-Log "OU déjà existante : $OUName" 'SKIP'
    }
    else {
        New-ADOrganizationalUnit -Name $OUName -Path $domaine.DistinguishedName
        Write-Log "OU créée : $OUName" 'OK'
    }
}
catch {
    Write-Log "Impossible de créer l'OU '$OUName' : $($_.Exception.Message)" 'ERREUR'
    exit 1   # sans OU, la suite ne peut pas fonctionner
}

# ─── Groupes ────────────────────────────────────────────────────────────────
foreach ($g in $groupes) {
    try {
        $existant = Get-ADGroup -Filter "SamAccountName -eq '$($g.Sam)' -or Name -eq '$($g.Name)'"
        if ($existant) {
            Write-Log "Groupe déjà existant : $($g.Name) ($($existant.DistinguishedName))" 'SKIP'
            $stats.GroupesExistants++
        }
        else {
            New-ADGroup -Name $g.Name -SamAccountName $g.Sam -GroupScope Global `
                -GroupCategory Security -Path $ouPath -Description $g.Description
            Write-Log "Groupe créé : $($g.Name)" 'OK'
            $stats.GroupesCrees++
        }
    }
    catch {
        Write-Log "Échec sur le groupe '$($g.Name)' : $($_.Exception.Message)" 'ERREUR'
        $stats.Erreurs++
    }
}

# ─── Utilisateurs ───────────────────────────────────────────────────────────
foreach ($u in $utilisateurs) {
    $nomComplet = "$($u.Prenom) $($u.Nom)"
    $upn        = "$($u.Sam)@$($domaine.DNSRoot)"

    try {
        # Un compte est considéré comme existant si l'identifiant, l'UPN ou le nom affiché est déjà pris
        $existant = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)' -or UserPrincipalName -eq '$upn' -or Name -eq '$nomComplet'"

        if ($existant) {
            Write-Log "Utilisateur déjà existant : $($u.Sam) ($($existant.DistinguishedName))" 'SKIP'
            $stats.UsersExistants++
        }
        else {
            New-ADUser -SamAccountName $u.Sam -UserPrincipalName $upn `
                -Name $nomComplet -DisplayName $nomComplet `
                -GivenName $u.Prenom -Surname $u.Nom -Department $u.Service `
                -Path $ouPath -AccountPassword $securePassword `
                -Enabled $true -ChangePasswordAtLogon $true
            Write-Log "Utilisateur créé : $($u.Sam) ($nomComplet)" 'OK'
            $stats.UsersCrees++
        }

        # Appartenance au groupe (seulement si pas déjà membre)
        $groupe  = Get-ADGroup -Identity $u.Groupe
        $membres = Get-ADGroupMember -Identity $groupe | Select-Object -ExpandProperty SamAccountName
        if ($membres -contains $u.Sam) {
            Write-Log "$($u.Sam) est déjà membre de $($groupe.Name)" 'SKIP'
        }
        else {
            Add-ADGroupMember -Identity $groupe -Members $u.Sam
            Write-Log "$($u.Sam) ajouté au groupe $($groupe.Name)" 'OK'
            $stats.AjoutsGroupe++
        }
    }
    catch {
        Write-Log "Échec sur l'utilisateur '$($u.Sam)' : $($_.Exception.Message)" 'ERREUR'
        $stats.Erreurs++
    }
}

# ─── Résumé ─────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "===== Résumé ====="
$stats.GetEnumerator() | ForEach-Object { Write-Output ("{0,-18}: {1}" -f $_.Key, $_.Value) }

if ($stats.Erreurs -gt 0) { exit 1 }
exit 0