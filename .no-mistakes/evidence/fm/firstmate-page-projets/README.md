# Page projets : preuves de test

Les captures montrent le HTML produit par les commandes `compose` puis `render`, ouvert dans Chrome installé, avec les styles du modèle livré (papaye-tokens).
Les données de flotte, les montants et les dates de ces captures sont des données de test, pas la flotte réelle du captain.

- `projets-desktop.png` : rail, trois badges, trois travaux visibles, sept blocs, cinq événements et désaccord entre les dates de l’agenda et du chat.
- `projets-mobile.png` : largeur 390 px, navigation horizontale et seul « Il manque de toi » ouvert.
- `projets-empty.png` : navigation vers Solos et états vides explicites.
- `projets-delivery-unavailable.png` : clic réel sans Lavish, refus visible de transmission.
- `projets-choice-simulated.png` : clic réel avec transport Lavish simulé, message de transmission et rappel de confirmation en chat ; les décisions restent présentes.
- `projets.html` et `projets-payload.json` : page portable et données composées correspondantes.
- `browser-checks.json` : observations et charge utile effectivement produite par le clic dans Chrome.
- `child-title-bearings.json` et `child-title-page.json` : titre obtenu après création d’une tâche avec tasks-axi, activité simulée, production réelle du résumé de foyer, lecture par le parent et composition de la page.
- `fixture-counterfactual.json` : même foyer refusé avec la racine du dépôt réel, puis accepté avec la racine de test distincte ; cause de l’échec initial du montage de test.

Le transport réussi vers Lavish et l’agenda sont simulés ; aucune réponse réelle n’a été envoyée et aucun calendrier n’a été modifié.
Le wireframe privé référencé dans l’intention n’est pas présent dans ce worktree : le contrôle visuel porte sur la structure décrite dans l’intention et le modèle livré.

Toutes les suites ciblées et le test Chrome opt-in ont terminé avec succès après correction de la racine du montage de test des événements. Aucun code produit n’a été changé.
