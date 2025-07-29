# Gestionnaire de Pare-feu Interactif pour Linux (iptables)

Ce script Shell propose une gestion interactive, sécurisée et persistante d'un pare-feu `iptables`. Il est destiné aux administrateurs systèmes et professionnels souhaitant configurer rapidement et efficacement les règles réseau d’un serveur Linux.

## Fonctionnalités

- Menu interactif en ligne de commande avec couleurs
- Sauvegarde automatique des règles actuelles
- Restauration automatique en cas de coupure SSH
- Détection réseau (interface, IP locale, IP publique)
- Configuration interactive complète ou rapide
- Support des règles personnalisées TCP/UDP
- Autorisation/bannissement par IP ou CIDR
- Options de sécurité : DDoS (rate limiting), logs, ping, etc.
- Test de connectivité après application des règles
- Persistance automatique via `iptables-persistent` ou `netfilter-persistent`
- Restauration possible via sauvegarde en cas de blocage

## Prérequis

- Linux avec `iptables` installé
- `bash`, `ss`, `curl`, `ip`, `netstat`, `who`, etc.
- Privilèges root

## Utilisation

1. Rendez le script exécutable :
   ```bash
   chmod +x iptables_script_config.sh
   ```

2. Lancez le script en tant que root :
   ```bash
   sudo ./iptables_script_config.sh
   ```

3. Choisissez une des options suivantes dans le menu :

   - **1** : Configuration interactive complète (avec timer de sécurité)
   - **2** : Charger et appliquer la configuration précédente
   - **3** : Configuration rapide (SSH + HTTP/HTTPS)
   - **4** : Afficher le statut du pare-feu
   - **5** : Désactiver complètement le pare-feu
   - **6** : Restaurer la dernière sauvegarde de règles
   - **7** : Quitter le script

## Fichiers générés

- `/tmp/iptables_backup_YYYYMMDD_HHMMSS.rules` : sauvegarde des règles précédentes
- `/tmp/firewall_restore.sh` : script de sécurité en arrière-plan
- `/var/log/firewall_config.log` : journal des opérations
- `firewall.conf` : configuration sauvegardée dans le dossier du script

## Bonnes pratiques

- Toujours tester la configuration avec la session SSH active avant validation
- Activer la persistance uniquement après validation manuelle
- Ne pas utiliser ce script sur des environnements critiques sans test préalable

## Sécurité

- Si une mauvaise configuration est appliquée, les règles sont automatiquement restaurées après 5 minutes
- La connexion SSH courante est détectée et protégée pendant l’application

## Auteurs

Ce script a été conçu pour des administrateurs systèmes ayant besoin d’un outil sûr et complet pour la gestion de `iptables`.

## Licence

Ce projet est fourni sans garantie, libre d’être modifié et adapté selon vos besoins.

### By DocteurMoriarty 