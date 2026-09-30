# Sections

## Aperçu
L'état en un coup d'œil : host, arrêt d'urgence, disjoncteur, approbations en attente, offres du jour.
Dessous : les agents actifs et les contrôles de santé, dont la RAM des résidents.

## Commandes
Les boutons d'AgentOS : Optimisation, Passover, Promouvoir, Market-Maker, Pitch, Drawback, Ménage. Chaque
lancement demande **Touch ID** ; le suivi est dans Runs. Dessous, les briefs en attente, écrits par /passover dans
Claude Code (ceux de la Conversation partent déjà validés) : tu les relis, tu les modifies ici ou dans Obsidian, tu
les valides (**Touch ID**), puis tu lances un brief validé.

## Approbations
Ce qu'un agent n'a pas le droit de faire seul. Tu approuves ou tu refuses, avec Touch ID.
Sans réponse avant le délai : refus. Chaque nouvelle demande envoie une notification.

## Runs
Chaque exécution d'un agent : source, statut, durée, journal. Un run appartient à une tâche.

## Tâches
Le travail confié aux agents. « En cours » par défaut ; « Toutes » montre aussi l'historique (terminées, tuées, annulées, échouées).

## Mémoire
Une recherche, deux sources : le vault et les documents, et les sessions ai-memory.
Clic sur une note : Obsidian. Clic sur une session : sa page. Filtre par source, tri par pertinence ou par date.

## Stockage
Disque libre et dernier scan d'optimisation.
« Copier » met la commande de nettoyage dans le presse-papiers : rien ne s'exécute, tu la lances toi-même.
« Lancer le scan » demande Touch ID.

## Veille emploi
Les offres du jour (job-radar), triées par étoiles, et le suivi des candidatures.
Clic sur une offre : navigateur. « Lancer job-radar » demande Touch ID.

## Réglages
Ouvrir à la connexion ; afficher la fenêtre au lancement.
Fenêtre au lancement désactivée : l'app démarre dans la barre des menus seule.

# Concepts

## Host
Le serveur local d'AgentOS (127.0.0.1:3107). L'app n'agit jamais seule : elle lit et commande par lui.

## Arrêt d'urgence
Actif : aucun nouveau run ne démarre. Le déclencher ou le lever demande Touch ID.

## Disjoncteur
S'ouvre seul après 3 échecs de suite : plus aucun lancement. « Fermé » est l'état normal.
Il se referme seul après un délai, ou tout de suite avec « Réarmer » (Touch ID).

## Touch ID
Tout ce qui lance, arrête ou autorise passe par Touch ID. Lire ne le demande jamais.

## Résidents
Les 5 processus toujours en marche : host, Hermès, freellmapi, ai-memory et l'app.
Plafond : 500 Mo à eux cinq (contrôle « residents » de l'Aperçu).

## Barre des menus et Dock
Fenêtre ouverte : icône dans le Dock. Fenêtre fermée : l'app reste dans la barre des menus
(approbations, arrêt d'urgence, « Ouvrir AgentOS »).

## Brief
Le contrat d'un run, rangé dans le vault (05-Agent-OS/passover). À la validation, AgentOS scelle son empreinte
(sha256) au journal : le run utilise exactement ce texte. Toute modification après validation en refait un brouillon.

## Mode agentique
Qui répond aux demandes de l'exécutant. Accepter les diffs : l'arbitre peut refuser, l'approbation reste à toi.
Auto : l'arbitre tranche seul les demandes « confirm » dans le mandat. Manuel n'apparaît que si Hermès demande
avant chaque action (mesuré le 2026-09-30 : il ne demande que pour les commandes dangereuses). Le hors mandat vient
toujours à toi. Un refus est définitif ; le contrat dit à l'exécutant de continuer sans, mais Hermès lui répond
d'attendre l'utilisateur : il peut s'arrêter là (fait F9).

## Origine d'une demande
Chaque demande dit qui la pose : moteur, modèle de l'exécutant (« gemma via Hermès »), run, mode agentique, et
« remontée par l'arbitre » avec sa raison. Hors mandat : Refuser (le run continue sans) ou Relancer avec ce mandat
(le run s'arrête, un brief élargi attend ta validation).
