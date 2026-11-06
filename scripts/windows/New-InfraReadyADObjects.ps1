<#
.SYNOPSIS
    Cree les OU, les groupes "Employes" et "IT" et 3 utilisateurs par groupe
    dans le domaine InfraReady.

.DESCRIPTION
    Script idempotent : chaque OU, groupe, utilisateur et appartenance a un
    groupe est verifie AVANT creation. Le script peut etre rejoue autant de
    fois que necessaire sans creer de doublon ni produire d'erreur.

    - Groupe deja present (meme nom ou meme SamAccountName) : non recree.
    - Utilisateur deja present (meme SamAccountName, UPN ou nom complet) :
      non recree, et son mot de passe n'est PAS modifie.
    - Appartenance deja en place : non rajoutee.

    Aucun mot de passe n'est ecrit dans ce fichier : le mot de passe initial
    est passe en parametre (depuis Ansible Vault quand le script est lance
    par Ansible). Les comptes devront changer ce mot de passe a la premiere
    connexion.

    Le fichier est volontairement en ASCII pur : Windows PowerShell 5.1 lit
    les .ps1 sans BOM avec l'encodage ANSI, ce qui corromprait les accents.
    Le "e" accentue de "Employes" est donc genere a l'execution.

.PARAMETER InitialPassword
    Mot de passe initial des nouveaux comptes. Il doit respecter la strategie
    de mot de passe du domaine (longueur, complexite).

.EXAMPLE
    # Execution manuelle sur WIN-DC01, PowerShell en administrateur :
    .\New-InfraReadyADObjects.ps1 -InitialPassword 'MotDePasse!Initial2026'

.NOTES
    Projet fil rouge InfraReady - Administration systemes Linux/Windows.
    Prerequis : module ActiveDirectory (present sur un controleur de domaine).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InitialPassword
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# --------------------------------------------------------------------------
# Donnees
# --------------------------------------------------------------------------
$NomEmployes = "Employ$([char]0x00E9)s"   # "Employes" avec e accentue

$domaine   = Get-ADDomain
$domainDN  = $domaine.DistinguishedName
$dnsRoot   = $domaine.DNSRoot

$ouRacine  = "OU=InfraReady,$domainDN"
$ouUsers   = "OU=Utilisateurs,$ouRacine"
$ouGroupes = "OU=Groupes,$ouRacine"

$groupes = @(
    @{ Name = $NomEmployes; Sam = 'Employes'; Description = 'Personnel des services metier' }
    @{ Name = 'IT';         Sam = 'IT';       Description = 'Equipe informatique' }
)

$utilisateurs = @(
    @{ Prenom = 'Alice';  Nom = 'Martin';  Sam = 'amartin';  Groupe = 'Employes'; Service = 'Comptabilite' }
    @{ Prenom = 'Bruno';  Nom = 'Petit';   Sam = 'bpetit';   Groupe = 'Employes'; Service = 'Ressources humaines' }
    @{ Prenom = 'Chloe';  Nom = 'Durand';  Sam = 'cdurand';  Groupe = 'Employes'; Service = 'Commercial' }
    @{ Prenom = 'David';  Nom = 'Leroy';   Sam = 'dleroy';   Groupe = 'IT';       Service = 'Informatique' }
    @{ Prenom = 'Emma';   Nom = 'Moreau';  Sam = 'emoreau';  Groupe = 'IT';       Service = 'Informatique' }
    @{ Prenom = 'Farid';  Nom = 'Benali';  Sam = 'fbenali';  Groupe = 'IT';       Service = 'Informatique' }
)

# --------------------------------------------------------------------------
# Suivi des resultats
# --------------------------------------------------------------------------
$script:changed = $false
$script:erreurs = New-Object System.Collections.Generic.List[string]
$script:stats   = [ordered]@{ Crees = 0; Existants = 0; Erreurs = 0 }

function Write-Etat {
    param([string]$Etat, [string]$Type, [string]$Nom, [string]$Detail = '')
    $ligne = '[{0,-8}] {1,-12} {2}' -f $Etat, $Type, $Nom
    if ($Detail) { $ligne += " ($Detail)" }
    Write-Output $ligne
}

function Add-Erreur {
    param([string]$Type, [string]$Nom, [string]$Message)
    $script:stats.Erreurs++
    $script:erreurs.Add("$Type $Nom : $Message")
    Write-Etat -Etat 'ERREUR' -Type $Type -Nom $Nom -Detail $Message
}

# --------------------------------------------------------------------------
# 1. Unites d'organisation
# --------------------------------------------------------------------------
function Confirm-OU {
    param([string]$Nom, [string]$Parent)
    try {
        $ou = Get-ADOrganizationalUnit -Filter "Name -eq '$Nom'" -SearchBase $Parent -SearchScope OneLevel
        if ($ou) {
            $script:stats.Existants++
            Write-Etat -Etat 'EXISTE' -Type 'OU' -Nom $Nom
        }
        else {
            New-ADOrganizationalUnit -Name $Nom -Path $Parent -ProtectedFromAccidentalDeletion $true
            $script:changed = $true
            $script:stats.Crees++
            Write-Etat -Etat 'CREE' -Type 'OU' -Nom $Nom
        }
    }
    catch {
        Add-Erreur -Type 'OU' -Nom $Nom -Message $_.Exception.Message
    }
}

Confirm-OU -Nom 'InfraReady'   -Parent $domainDN
Confirm-OU -Nom 'Utilisateurs' -Parent $ouRacine
Confirm-OU -Nom 'Groupes'      -Parent $ouRacine

# Sans les OU, la suite ne peut pas fonctionner : on s'arrete proprement.
if ($script:stats.Erreurs -gt 0) {
    throw "Echec de creation des OU, arret du script. $($script:erreurs -join ' | ')"
}

# --------------------------------------------------------------------------
# 2. Groupes : verification par nom ET par SamAccountName
# --------------------------------------------------------------------------
foreach ($g in $groupes) {
    try {
        $existant = Get-ADGroup -Filter "SamAccountName -eq '$($g.Sam)' -or Name -eq '$($g.Name)'"
        if ($existant) {
            $script:stats.Existants++
            Write-Etat -Etat 'EXISTE' -Type 'Groupe' -Nom $g.Sam -Detail $existant.DistinguishedName
        }
        else {
            New-ADGroup -Name $g.Name `
                        -SamAccountName $g.Sam `
                        -GroupCategory Security `
                        -GroupScope Global `
                        -Path $ouGroupes `
                        -Description $g.Description
            $script:changed = $true
            $script:stats.Crees++
            Write-Etat -Etat 'CREE' -Type 'Groupe' -Nom $g.Sam
        }
    }
    catch {
        Add-Erreur -Type 'Groupe' -Nom $g.Sam -Message $_.Exception.Message
    }
}

# --------------------------------------------------------------------------
# 3. Utilisateurs : verification par SamAccountName, UPN et nom complet
# --------------------------------------------------------------------------
$motDePasse = ConvertTo-SecureString $InitialPassword -AsPlainText -Force

foreach ($u in $utilisateurs) {
    $nomComplet = "$($u.Prenom) $($u.Nom)"
    $upn        = "$($u.Sam)@$dnsRoot"

    try {
        $existant = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)' -or UserPrincipalName -eq '$upn' -or Name -eq '$nomComplet'"
        if ($existant) {
            $script:stats.Existants++
            Write-Etat -Etat 'EXISTE' -Type 'Utilisateur' -Nom $u.Sam -Detail 'mot de passe non modifie'
        }
        else {
            New-ADUser -Name $nomComplet `
                       -GivenName $u.Prenom `
                       -Surname $u.Nom `
                       -DisplayName $nomComplet `
                       -SamAccountName $u.Sam `
                       -UserPrincipalName $upn `
                       -Department $u.Service `
                       -Path $ouUsers `
                       -AccountPassword $motDePasse `
                       -ChangePasswordAtLogon $true `
                       -Enabled $true
            $script:changed = $true
            $script:stats.Crees++
            Write-Etat -Etat 'CREE' -Type 'Utilisateur' -Nom $u.Sam
        }
    }
    catch {
        Add-Erreur -Type 'Utilisateur' -Nom $u.Sam -Message $_.Exception.Message
        continue   # inutile de tenter l'ajout au groupe d'un compte non cree
    }

    # 4. Appartenance au groupe, ajoutee seulement si absente
    try {
        $membres = @(Get-ADGroupMember -Identity $u.Groupe | Select-Object -ExpandProperty SamAccountName)
        if ($membres -contains $u.Sam) {
            Write-Etat -Etat 'EXISTE' -Type 'Membre' -Nom "$($u.Sam) -> $($u.Groupe)"
        }
        else {
            Add-ADGroupMember -Identity $u.Groupe -Members $u.Sam
            $script:changed = $true
            Write-Etat -Etat 'AJOUTE' -Type 'Membre' -Nom "$($u.Sam) -> $($u.Groupe)"
        }
    }
    catch {
        Add-Erreur -Type 'Membre' -Nom "$($u.Sam) -> $($u.Groupe)" -Message $_.Exception.Message
    }
}

# --------------------------------------------------------------------------
# Bilan
# --------------------------------------------------------------------------
Write-Output ('Bilan : {0} cree(s), {1} deja existant(s), {2} erreur(s)' -f `
              $script:stats.Crees, $script:stats.Existants, $script:stats.Erreurs)

# Quand le script est lance par le module Ansible win_powershell, la variable
# $Ansible existe : on lui indique s'il y a eu un changement reel, ce qui
# donne changed=0 au second passage (idempotence visible dans le PLAY RECAP).
if (Get-Variable -Name Ansible -ErrorAction SilentlyContinue) {
    $Ansible.Changed = $script:changed
}

if ($script:stats.Erreurs -gt 0) {
    throw "Le script s'est termine avec $($script:stats.Erreurs) erreur(s) : $($script:erreurs -join ' | ')"
}
