# Playdeck

Application macOS pour **déployer des playbooks Ansible en un clic**, sans ligne de commande.

On ajoute ses projets Ansible, on coche des machines et des playbooks, on clique sur **Déployer** :
Playdeck lance `ansible-playbook`, affiche le log en direct et le résultat de chaque machine.

## Fonctionnalités

- **Plusieurs projets** : ajoutez un dossier (bouton ou glisser-déposer) ; chaque sous-dossier qui est un projet
  Ansible (un inventaire + au moins un playbook) apparaît dans le menu.
- **Déploiement simple** : choix des machines et des playbooks ; chaque playbook ne part que sur les machines
  de son `hosts:`. Mode **simulation** (`--check`) activé par défaut, confirmation avant chaque lancement.
- **Options sans terminal** : variables `-e`, `--tags`, `--skip-tags`, `--diff`, verbosité.
- **Secrets** : mot de passe `ansible-vault` rangé dans le Trousseau macOS, mot de passe sudo demandé au besoin ;
  ni l'un ni l'autre n'est jamais écrit sur disque ni dans les logs.
- **Suivi des versions** : après un déploiement réussi, Playdeck note le hash du code dans un dossier `.playdeck/`
  du projet. Si le code change, les machines concernées passent « en retard », avec la liste des fichiers modifiés.
- **Historique** de tous les lancements, exportable en CSV ou JSON, et notification en fin de déploiement.

## Prérequis

- macOS 14 ou plus récent
- Ansible installé (`brew install ansible`)
- Swift 6 (outils en ligne de commande Xcode)

## Lancer l'application

```bash
cd Playdeck
swift run Playdeck                 # lancement direct
scripts/build-app.sh               # ou construire Playdeck.app (dans Playdeck/build/)
cp -R build/Playdeck.app /Applications/
```

Tests : `cd Playdeck && swift test`

## Organisation du code

| Dossier | Contenu |
|---|---|
| `Playdeck/Sources/PlaydeckCore` | Logique : projets Ansible, lancement de `ansible-playbook`, suivi des versions, historique, secrets |
| `Playdeck/Sources/Playdeck` | Interface SwiftUI |
| `Playdeck/Tests` | Tests (`swift test`) |
| `Playdeck/scripts` | Construction de `Playdeck.app` et génération de l'icône |
