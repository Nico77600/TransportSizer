# Transport Sizer – méthode de dimensionnement

Version 1.10.0 · Nicolas Fabert

Ce document explique comment Transport Sizer calcule chaque chiffre pour un serveur **Edge Transport** ou un serveur **Mailbox qui ne fait que du transport** (relais, sans boîtes aux lettres d’utilisateurs, avec ou sans DAG), en **virtuel** ou en **physique**. Le rapport technique (`TransportSizer.html`) reprend les mêmes calculs, ligne par ligne, avec les valeurs du scénario ; la synthèse client (`TransportSizer-Synthese.html`) en présente le résultat de façon visuelle : architecture, configuration de chaque serveur, capacité par seconde, heure et jour, journée type, réseau, incident.

## 1. Pourquoi un outil à part

Le calculateur Microsoft (Exchange Server Role Requirements Calculator 10.7) ne dimensionne le transport que par la taille de la base de file d’attente :

> messages par jour et par serveur × 2 (shadow) × (1 + 0,5 × jours d’expiration + jours de Safety Net) × taille moyenne

Il ne donne ni processeur, ni mémoire, ni IOPS, ni réseau pour le transport, et il applique Safety Net et la redondance shadow à tous les serveurs, Edge compris. Transport Sizer :

- sépare **Edge** (ni Safety Net, ni redondance shadow) et **Mailbox** (Safety Net et copies shadow, même sans boîte aux lettres) ;
- construit la file d’attente à partir de ses causes (transit, panne du saut suivant, Safety Net, copies shadow, espace non récupéré) ;
- ne tire **processeur, mémoire et IOPS que de mesures**. Par défaut, ce sont les **profils de référence** mesurés au labo et livrés avec l’outil : un projet sans aucun serveur Exchange à mesurer se dimensionne quand même, de façon générique. Le profil mesuré sur un serveur du client les remplace, et trois ajustements (processeur, E/S, mémoire au repos) adaptent l’un ou l’autre au contexte. Aucune constante générique n’est transformée en résultat ;
- applique les seuils de back pressure d’Exchange, la pénalité RAID et la réserve de reconstruction en physique ;
- garde le résultat du calculateur Microsoft en comparaison.

## 2. Edge et Mailbox de transport : ce qui change

| | Edge Transport | Mailbox (transport seul) |
|---|---|---|
| Safety Net | Non | Oui : chaque message traité est gardé `SafetyNetHoldTime` (2 jours par défaut), ou le délai de relecture des copies décalées s’il est plus long |
| Redondance shadow | Non | Oui, si au moins deux serveurs restent dans la frontière : le DAG, ou le site AD hors DAG. Le serveur garde pour ses voisins autant de copies que ses voisins en gardent pour lui |
| Rapports de journal | Non (écrits par les serveurs Mailbox) | Oui, flux calculé ; ils n’ont pas de copie shadow |
| Réseau | Deux cartes : externe (Internet) et interne (organisation) | Une carte, copies shadow comprises |
| Coût processeur d’un message (labo) | 0,02 processeur par msg/s (REF-EDGE, 75 Ko) | 0,13 processeur par msg/s (REF-MAILBOX, 75 Ko) : six à sept fois plus |
| Mémoire par message en file (labo) | 63 Ko complet, 22 Ko déshydraté | 58 Ko complet, 20 Ko déshydraté (par analogie) |
| RAM recommandée par Microsoft (information) | 64 Go | 128 Go |

## 3. Les entrées

| Groupe | Entrées | Origine conseillée |
|---|---|---|
| Rôle et déploiement | Edge ou Mailbox, virtuel ou physique | Projet |
| Topologie | Sites, serveurs par site, panne à absorber (aucune, un serveur, deux serveurs, un site), DAG | Projet |
| Flux | Pour chaque flux : sens (entrant, sortant, interne), messages par jour pour toute l’organisation, taille moyenne, transmissions SMTP par message, retenu ou non pendant une panne | Exchange Log Report (import) ou suivi des messages |
| Charge | Croissance, facteur de rafale, règles de transport, part des sessions en TLS, messages par session | Exchange Log Report, configuration |
| Journée de trafic | Heures ouvrées par jour, part du trafic hors heures ouvrées, durée de la pointe (heures), pointe : part du jour par heure de pointe **ou** débit de pointe mesuré pour l’organisation, en messages par heure ou par seconde | Exchange Log Report (import), suivi des messages par heure |
| Résilience | Expiration des messages, durée de panne du saut suivant, séjour en transit, `SafetyNetHoldTime`, redondance shadow, délai de relecture, jours entre deux récupérations de l’espace de `mail.que`, durée de vidange visée (12 h) | Configuration Exchange, exigences |
| Journalisation (Mailbox) | Portée, part journalisée, destinations, enveloppe, destination interne ou externe | Règles de journal |
| Stockage, calcul, réseau | Volume de file dédié ou non, remplissage maximal, surcoût d’E/S, tailles du système, processeur de l’hôte (SPECint par cœur), vCPU par cœur physique (2:1), gain de l’hyperthreading (20 %), CPU maximal, surcoût d’hyperviseur, minimum de cœurs (4), vCPU en nombre pair, marge et minimum de RAM, mémoire réservée (100 %), carte réseau | Normes du client, inventaire des hôtes |
| Physique | SPECint_rate2017, cœurs, type et taille des disques, RAID | Fiche du serveur |
| Profil | Profil de référence du rôle (par défaut), ou profil mesuré sur un serveur du client ; ajustements processeur (%), E/S (%), mémoire au repos (Go) | Labo (référence), `calibration\Measure-TransportLoad.ps1`, contexte du client |

## 4. Le calcul, étape par étape

### 4.1 Trafic par serveur

1. Serveurs restants = sites × serveurs par site − serveurs perdus par la panne retenue. Tout le trafic de l’organisation passe par eux.
2. Messages par jour = Σ flux × (1 + croissance).
3. Messages par jour et par serveur = messages par jour ÷ serveurs restants.
4. Taille moyenne = Σ (messages × taille) ÷ Σ messages.
5. Part de l’heure de pointe : débit de pointe mesuré (messages par heure de l’organisation, ou par seconde × 3 600) ÷ messages par jour saisis ; à défaut, la part saisie. Exemple : 300 000 messages par heure pour 2 millions par jour = 15 % du jour par heure de pointe.
6. Profil horaire de la journée : les heures de pointe à cette part, les autres heures ouvrées se partagent le reste de la journée de travail, les heures hors journée se partagent le trafic hors heures ouvrées. Contrôles :
   - les heures de pointe ne peuvent pas porter plus que la journée de travail (erreur) ;
   - une pointe inférieure à la moyenne des heures ouvrées est relevée à cette moyenne (avertissement) ;
   - une pointe inférieure à la moyenne sur 24 h est refusée.
7. Débit de l’heure de pointe = messages par jour et par serveur × part de l’heure de pointe ÷ 3 600, affiché aussi en messages par heure.
8. **Débit de dimensionnement** = débit de pointe × facteur de rafale.
9. Débit moyen des heures ouvrées = messages par jour et par serveur × (1 − part hors heures ouvrées) ÷ heures ouvrées ÷ 3 600 : c’est le trafic qui continue pendant une vidange en journée.
10. Facteurs de charge au débit de dimensionnement : Mo/s (débit × taille ÷ 1 024), messages × règles, sessions par seconde (débit ÷ messages par session), sessions TLS, Mo/s chiffrés, rapports de journal par seconde.

### 4.2 File d’attente (`mail.que`)

Le volume de la file doit contenir, au pire moment :

| Part | Calcul | Rôle |
|---|---|---|
| Transit | Loi de Little : débit de dimensionnement × temps de séjour (60 s par défaut ; 10 s mesurés sur REF-EDGE) | Les deux |
| Panne du saut suivant | Σ flux retenus : messages par jour et par serveur × part accumulée. Part accumulée = jours entiers + parts des heures les plus chargées du profil horaire pour les heures restantes (la pointe, puis le reste de la journée de travail, puis les heures hors journée), durée plafonnée à l’expiration des messages | Les deux |
| Safety Net | Messages par jour et par serveur × rétention en jours | Mailbox |
| Copies shadow | Transit + panne + Safety Net des messages reçus (pas des rapports de journal), si la redondance shadow est effective | Mailbox |

Puis :

- données = Σ messages × taille ;
- **`mail.que` = 0,5 Go (base vide, mesurée) + données × facteur ESE + messages remis non récupérés** ;
- facteur ESE : mesuré pendant un palier backlog (1,245 sur REF-EDGE), ou, sur un profil Mailbox, croissance de `mail.que` par Mo stocké (1,19 sur REF-MAILBOX, car Safety Net garde tout) ;
- messages remis non récupérés : l’espace des messages remis n’est réutilisé qu’après un redémarrage du transport ou la défragmentation en ligne quotidienne (mesuré sur REF-EDGE). Le moteur ajoute donc le trafic de `SpaceReclaimDays` jours (1 par défaut) × taille × facteur, copies shadow comprises sur Mailbox ;
- journaux de transactions = 3 × `DatabaseCheckPointDepthMax` (384 Mo), plus les autres données de `TransportRoles\data` ;
- **volume de la file = contenu ÷ min(remplissage maximal, seuil de back pressure)**. Le seuil retenu est le plus bas de `DatabaseUsedSpace` (96 %) et de `UsedDiskSpace` des journaux (89 %). En virtuel, le disque est arrondi au multiple supérieur (10 Go par défaut).

### 4.3 Processeur

Le profil de calibration donne un modèle linéaire du CPU total du serveur de référence :

> CPU % = à vide + a × msg/s + b × Mo/s + c × msg/s × règles + d × sessions/s + e × sessions TLS/s + f × Mo/s TLS + g × rapports de journal/s

Chaque terme n’existe que si les paliers de calibration l’ont fait varier. Ensuite, le moteur convertit le travail mesuré sur la référence en unités de la cible (vCPU ou cœurs), avec la performance des processeurs (SPEC CPU2017 integer rate par cœur, « SPECint ») et ce qu’un vCPU obtient vraiment d’un cœur.

1. processeurs logiques occupés sur la référence = CPU % ÷ 100 × processeurs logiques ;
2. × correction de validation : max(1, CPU mesuré ÷ CPU prédit) d’un palier de mélange gardé hors de l’ajustement (1,24 sur REF-EDGE) ;
3. **capacité d’un processeur logique de la référence** :
   - thread qui partage son cœur (moins de cœurs que de processeurs logiques : vCPU Azure, serveur avec hyperthreading) = SPECint par cœur × cœurs ÷ processeurs logiques. Sur REF-EDGE et REF-MAILBOX, deux vCPU sont les deux threads d’un cœur de Xeon Platinum 8573C : 8,5 ÷ 2 = 4,25 ;
   - vCPU d’une VM sans hyperthreading visible = SPECint par cœur ÷ (1 + gain de l’hyperthreading) : il avait un cœur pour lui seul pendant la calibration ;
   - cœur d’un serveur physique sans hyperthreading = SPECint par cœur ;
4. **capacité garantie d’un vCPU de la cible** = SPECint par cœur de l’hôte ÷ max(vCPU par cœur physique, 1 + gain de l’hyperthreading). À 1:1, un vCPU a un cœur, mais un seul thread : 83 % du cœur avec un gain de 20 %. À 2:1, la moitié d’un cœur ; à 3:1, un tiers. Un **cœur d’un serveur physique** compte entier (ses deux threads) ;
5. unités de la cible par processeur logique de la référence = capacité de la référence ÷ capacité de la cible ;
6. × surcoût d’hyperviseur si la cible et la référence n’ont pas le même mode (10 %) ;
7. × ajustement processeur du profil (100 % par défaut) ;
8. cœurs pour la vidange visée = (CPU de la référence au débit moyen des heures ouvrées + CPU d’un message renvoyé × messages à vider ÷ durée visée) ÷ 100 × processeurs logiques, avec les mêmes facteurs (voir 4.8) ;
9. **unités proposées = max(minimum (4), ⌈unités nécessaires ÷ utilisation maximale (80 %)⌉, ⌈unités pour la vidange ÷ 80 %⌉)**, **arrondies au nombre pair de vCPU** en virtuel. En physique, les cœurs saisis sont gardés et leur utilisation affichée ; calculés, ils sont aussi arrondis au nombre pair.

**Pourquoi pas la formule du calculateur Microsoft.** Le calculateur convertit le SPECint par cœur de l’hôte en mégacycles, puis le divise par 1 ou par 2 selon le ratio vCPU (1:1 ou 2:1). Trois défauts :
- à 1:1, il donne à un vCPU tout le débit d’un cœur avec ses deux threads, alors qu’un vCPU n’en utilise qu’un (environ 83 %) ;
- il ne connaît que 1:1 et 2:1, alors que les clusters réels sont souvent à 3:1 ou 4:1 ;
- il ne dit pas ce que valait un processeur logique de la référence : un vCPU Azure est un thread, la moitié d’un cœur. Transport Sizer comparait d’ailleurs jusqu’en 1.7 un thread de la référence à un cœur physique entier de la cible : le nombre de cœurs d’un serveur physique était doublé.

**Valeurs par défaut.** Ratio de 2 vCPU par cœur (2:1) : c’est le maximum que Microsoft prend en charge pour Exchange (1:1 recommandé), et la pratique courante des clusters partagés. Au-delà de 2:1, le rapport avertit : le calcul donne plus de vCPU, mais un serveur Exchange n’est plus dans une configuration prise en charge. Une VM avec une réservation processeur complète se saisit à 1:1. Gain de l’hyperthreading : 20 %, médiane de cinq systèmes mesurés par SPEC avec et sans SMT (3 à 22 %).

**SPECint par cœur.** La liste « Processeur de l’hôte ou du serveur » de la fenêtre (69 processeurs Xeon et EPYC, de Broadwell à Emerald Rapids et Turin) donne la médiane des résultats SPEC CPU2017 integer rate (base) publiés sur spec.org, divisée par les cœurs (`data\Processors.csv`, 7 octobre 2026). Le Xeon Platinum 8573C des VM du labo est un modèle propre à Azure, sans résultat publié : sa valeur (8,5) est celle du Xeon Platinum 8580, de même génération et de même nombre de cœurs. Exemples : Xeon Gold 6140 (2017) 5,1 ; Gold 6248R 6,8 ; Gold 6338 6,5 ; Gold 5418Y 8,8 ; Gold 6542Y 10,7 ; EPYC 9354 11,6.

Pourquoi 4 vCPU au moins et un nombre pair : en dessous de 4, Windows, Exchange, l’antivirus et les agents de supervision n’ont pas de marge, et une rafale ou une vidange sature le serveur. Un nombre pair s’aligne sur les sockets × cœurs et le vNUMA de VMware et Hyper-V, et sur les paires de threads d’un cœur physique. Les deux règles sont des entrées (`MinCores`, `EvenVcpu`) ; un scénario enregistré avant la version 1.7 garde ses 2 cœurs minimum, sans arrondi.

Exemple : l’Edge à 2 millions de messages entrants et 1 million sortants par jour (4 serveurs, 2 restants, pointe de 37,5 msg/s par serveur, TLS) occupe 1,38 processeur logique de la référence.

| Hôte | 1:1 | 2:1 | 3:1 |
|---|---|---|---|
| Même cœur que la référence (8,5) | 0,8 vCPU → 4 vCPU à 21 % | 1,4 → 4 vCPU à 34 % | 2,1 → 4 vCPU à 52 % |
| Xeon Gold 6140 (5,1, 2017) | 1,4 → 4 vCPU à 34 % | 2,3 → 4 vCPU à 57 % | 3,4 → 6 vCPU à 57 % |
| Xeon Gold 6338 (6,5, 2021) | 1,1 → 4 vCPU à 27 % | 1,8 → 4 vCPU à 45 % | 2,7 → 4 vCPU à 68 % |
| EPYC 9354 (11,6, 2022) | 0,6 → 4 vCPU à 15 % | 1,0 → 4 vCPU à 25 % | 1,5 → 4 vCPU à 38 % |

Quand le profil a mesuré les rapports de journal, ceux-ci sortent des messages reçus par SMTP : ils ne comptent ni dans le débit, ni dans les Mo/s, ni dans les sessions, mais dans le terme g.

### 4.4 Mémoire

1. Messages en file au pire moment = transit + panne (× 2 avec les copies shadow, hors rapports de journal). Safety Net reste dans la base, pas en mémoire.
2. Mémoire des messages en file = transit × Ko par message complet + panne × Ko par message **déshydraté**. Message complet : pente mesurée pendant le palier backlog (63,5 Ko sur REF-EDGE, 58 Ko sur REF-MAILBOX, messages de 75 Ko). Message déshydraté : 22 Ko mesurés sur REF-EDGE ; 20 Ko sur Mailbox, par analogie (même rapport).
3. Mémoire privée d’EdgeTransport.exe = modèle mesuré au débit de dimensionnement + messages en file ; RAM pour rester sous le seuil de back pressure `PrivateBytes` = ÷ 72 %.
4. Mémoire utilisée par tous les processus = modèle mesuré + messages en file ; RAM pour rester sous `SystemMemory` = ÷ 88 %. Si la mémoire au repos d’un serveur du client est saisie, elle remplace celle du profil (l’ordonnée du modèle) ; la part qui suit la charge reste celle du profil.
5. **RAM proposée = max des deux × (1 + marge 10 %)**, au multiple de 4 Go supérieur, au moins le minimum (8 Go). Fichier d’échange : 25 % de la RAM, taille fixe.
6. Messages de la panne gardés complets avant la première déshydratation = place laissée sous le premier seuil atteint ÷ Ko par message complet, avec le seuil atteint en premier.
7. En virtuel, **mémoire à réserver au minimum sur l’hôte** = RAM nécessaire au pire moment, sans la marge (arrondie au Go) ; RAM nécessaire hors panne = même calcul avec les seuls messages en transit.

**Réservation de la mémoire.** Microsoft ne prend pas en charge la mémoire dynamique ni la surallocation de mémoire pour Exchange : la réservation complète (100 %) reste la valeur par défaut. Comme elle n’est pas toujours appliquée, l’entrée « Mémoire réservée (%) » dit ce qui est garanti, et le rapport la compare aux deux besoins :
- au-dessus du besoin au pire moment : seule la marge (et l’arrondi) est partagée avec l’hôte, information ;
- entre le besoin hors panne et le besoin au pire moment : avertissement. La file d’une panne n’est plus garantie, alors que c’est pendant une panne ou une bascule de site que l’hôte est le plus chargé et reprend de la mémoire ;
- sous le besoin hors panne : avertissement, la VM dépend de la mémoire libre de l’hôte même sans incident.

Si l’hôte reprend la mémoire par ballooning, Windows la voit occupée : Exchange déshydrate plus tôt et, si EdgeTransport atteint 72 %, refuse temporairement des messages. S’il la met dans son propre fichier d’échange, Exchange ne voit rien et tout ralentit. Pour l’Edge à 2 + 1 millions de messages (24 h de panne), 60 Go de RAM, 55 Go au moins à réserver, 4,2 Go suffisent hors panne : c’est la file d’une longue panne qui fait la mémoire.

**Pourquoi la file de la panne est comptée déshydratée.** Exchange ne garde pas en mémoire tout le contenu d’une longue file. Quand la mémoire utilisée atteint 88 % (`SystemMemory`, niveau moyen) ou qu’EdgeTransport atteint 72 % de la RAM (`PrivateBytes`, niveau moyen), il déshydrate les messages en file : leur contenu quitte la mémoire et sera relu dans `mail.que` à l’envoi (`DehydrateMessagesUnderMemoryPressure`, actif par défaut). Mesuré sur REF-EDGE (8 Go) le 7 octobre 2026 : 195 898 messages de 75 Ko accumulés en une heure à 54 msg/s, saut suivant coupé. À chaque passage à 88 % (cinq fois entre 72 000 et 188 000 messages), la mémoire privée d’EdgeTransport est retombée, par exemple de 5,1 à 2,9 Go à 93 700 messages : il reste 20 à 22 Ko par message. Aucune contre-pression, aucun message refusé, la réception a continué. La RAM doit donc tenir la file déshydratée sous les seuils ; la file complète n’est qu’un cache, que la RAM en plus permet de garder plus longtemps.

Le niveau moyen de `SystemMemory` déshydrate sans rien refuser. Celui de `PrivateBytes` déshydrate aussi, mais refuse en plus les messages des serveurs non Exchange (Internet) jusqu’au retour sous le seuil. Sur un serveur où la mémoire hors EdgeTransport pèse moins de 16 % de la RAM (un Edge à partir de 16 Go environ), `PrivateBytes` est atteint en premier : le rapport l’annonce (refus temporaires 4xx, l’expéditeur réessaie), d’après les seuils documentés par Microsoft. Ce cas n’a pas été observé au labo, où la mémoire totale atteint 88 % en premier sur 8 Go.

### 4.5 Disques

- IOPS du volume de la file = (lectures + écritures des modèles mesurés) × (1 + surcoût d’E/S, 20 %) × ajustement E/S du profil ; débit d’écriture en Mo/s du modèle des octets écrits, avec le même ajustement.
- Volume système = Windows + binaires + espace libre exigé à l’installation + journaux de diagnostic + journaux de transport + fichier d’échange (+ la file si elle n’a pas de volume dédié), ÷ remplissage maximal.
- **Physique** : capacité formatée par disque = capacité brute × 10⁹ ÷ 2³⁰ ; IOPS physiques = (lectures + écritures × pénalité RAID) × (1 + surcoût) ÷ (1 − réserve de reconstruction) ; disques = max(disques pour la capacité, disques pour les IOPS) selon le RAID choisi. Le RAID-1 passe en RAID-1/0 quand un disque ne suffit pas.
- **Catalogue fabricants** : `data\Disks.csv` reprend celui de Mailbox Sizer, avec modèles, classes génériques fondées sur un modèle de référence, capacités, endurance, conditions des valeurs, URL constructeur et date de vérification. Plus d’IOPS issues de l’ancienne table Microsoft. Disques système et file choisis séparément : M.2 de démarrage en RAID-1 pour le système et SSD SAS usage mixte 3 DWPD pour la file par défaut. Les disques mécaniques restent sélectionnables, avec les limites explicites de leurs données.
- **Capacité automatique** : `DiskSizeGB` et `SystemDiskSizeGB` à 0 essaient les capacités du modèle et gardent le groupe RAID avec le moins de disques, puis la plus petite capacité à égalité. Pour une classe générique, le débit séquentiel est celui du modèle le plus lent réellement disponible dans chaque capacité, avant de calculer ses IOPS et son RAID : un disque 8 To n’hérite pas du débit du HC580 22 To. NL-SAS : 8 To et plus ; SSD/NVMe : 900 Go et plus, comme Mailbox Sizer. Les M.2 de démarrage et les 10K ont leurs capacités propres. Une capacité saisie hors catalogue est conservée et signalée.
- **IOPS HDD** : budget mixte à file courte, 220 IOPS à 4 Ko pour le WD HC580 (file 4, environ 18 ms), référence de la classe NL-SAS. Pour les modèles qui ne publient pas cette mesure, l’analogie avec la référence est annoncée. Les 10K sans valeur mixte publiée ne reçoivent pas arbitrairement 165 IOPS : dimensionnement par capacité seulement, marqué incomplet, ou mesure saisie.
- **Adaptation au transport** : les E/S de `mail.que` et de ses journaux restent celles du profil mesuré. Taille moyenne retenue = `(octets lus/s + octets écrits/s × pénalité RAID) ÷ (lectures/s + écritures/s × pénalité RAID) ÷ 1 024`, ou `Physical.IoSizeKB` si saisi. Ce n’est ni la taille d’un message, ni une page de base de boîte de 32 Ko imposée au transport. Pour un HDD : `1 ÷ (1 ÷ IOPS 4 Ko + max(taille − 4, 0) Ko ÷ débit séquentiel)`, arrondi vers le bas (215 IOPS si 32 Ko sur HC580). Pour un SSD : `min(IOPS aléatoires d’écriture 4 Ko, débit d’écriture ÷ max(taille, 4) Ko)`, arrondi vers le bas. Débits de fiches décimaux en Mo/s convertis en octets avant de comparer aux Ko binaires des compteurs. Ce sont des budgets de conception, à confirmer sur le disque de la capacité exacte, le contrôleur, les caches et la charge mixte ; pas une garantie de latence.
- **Mesures personnalisées** : `DiskIops` et `SystemDiskIops` à 0 utilisent le catalogue ; une valeur positive remplace l’estimation par la mesure par disque pour la charge transport réelle. Sans modèles d’octets dans un ancien profil, le budget 4 Ko reste provisoire et les IOPS sont marquées incomplètes, sauf taille ou IOPS mesurées saisies. Les anciens noms de disques et `SsdIops` s’importent toujours, mais les résultats physiques sont recalculés avec les nouvelles données.
- **Protection et endurance** : RAID protégé uniquement (1, 1/0, 5 ou 6) ; RAID-5 de plus de 7 disques signalé. Vérifier l’endurance des SSD lecture intensive ou de démarrage si la file est sur le système ; préférer un SSD usage mixte. Dans ce placement, seules les données du disque système dimensionnent la file.

### 4.6 Réseau

- Par flux : débit × taille × 8 × (1 + surcoût protocolaire 5 %) ; en émission, × transmissions par message (un envoi par domaine ou serveur de destination).
- **Edge** : carte externe (entrant reçu, sortant émis) et carte interne (sortant reçu, entrant émis).
- **Mailbox** : une carte, plus les copies shadow dans chaque sens (une copie de chaque message reçu vers un autre serveur, autant reçues des autres).
- Utilisation = carte la plus chargée ÷ débit de la carte, comparée à l’utilisation maximale (70 %).

### 4.7 Journalisation (Mailbox)

L’agent de journalisation écrit un rapport par message journalisé et par destination de journal : le message d’origine est joint, inchangé, avec une enveloppe (4 Ko par défaut). Le moteur ajoute un flux « Rapports de journal (calculé) » :

- rapports par jour = Σ flux dans la portée × part journalisée × destinations ;
- taille = taille du message + enveloppe ;
- sens : sortant (archive externe) ou interne (boîte de journalisation).

Les rapports comptent dans la file, Safety Net, la mémoire, le réseau et le processeur, mais **pas dans les copies shadow** : sur REF-MAILBOX, un message journalisé donne trois envois SMTP (saut suivant, copie shadow, rapport), pas quatre. Une journalisation de tous les messages double donc presque le volume traité. Si l’archive externe passe par des Edge, il faut ajouter les rapports en flux sortant au dimensionnement des Edge.

### 4.8 Débit maximal et vidange

- Débit maximal permis par le processeur = débit qui amène les cœurs proposés à l’utilisation maximale, avec les mêmes facteurs par message.
- Débit maximal permis par le réseau = débit de dimensionnement × (débit de la carte × utilisation maximale) ÷ charge de la carte.
- Une panne en journée se vide pendant que le trafic de la journée continue. **Débit de vidange = (capacité des cœurs proposés à 80 % − CPU au débit moyen des heures ouvrées) ÷ CPU d’un message renvoyé depuis la file**, plafonné par le réseau et par le débit de vidange mesuré.
- Renvoyer un message depuis la file coûte bien moins que le recevoir (pas d’antispam ni d’analyse) : sur REF-EDGE, 0,11 % de CPU par msg/s, contre 1,05 % pour un message reçu de 75 Ko. Les 195 898 messages déshydratés du test ont été vidés en 33,6 min à 97,5 msg/s avec 13 % de CPU et une lecture de `mail.que` par message : c’étaient les serveurs Mailbox du labo qui donnaient le rythme. Au-delà de ce débit mesuré, rien ne dit que le serveur enverrait plus vite : le moteur s’y arrête. Sur Mailbox, le coût est déduit par analogie (même rapport entre message renvoyé et message reçu), plafonné aux 200 msg/s observés sur REF-MAILBOX.
- **Durée de vidange = messages accumulés ÷ (débit de vidange × 3 600)**. Avec une durée visée (`DrainTargetHours`, 12 h par défaut), les cœurs sont dimensionnés pour la tenir (4.3) ; le rapport avertit si le réseau ou le débit de vidange mesuré l’empêchent.
- IOPS pendant la vidange = E/S des heures ouvrées + débit de vidange × E/S mesurées par message renvoyé (1,05 sur REF-EDGE : la relecture des messages déshydratés).

### 4.9 Virtuel ou physique

| | Virtuel | Physique |
|---|---|---|
| Processeur | Un vCPU = SPECint par cœur de l’hôte ÷ max(ratio vCPU, 1,2) ; vCPU = max(4, ⌈vCPU nécessaires ÷ 80 %⌉, vCPU pour la vidange), arrondis au nombre pair ; surcoût d’hyperviseur si la référence était physique | Un cœur entier (ses threads compris) ; cœurs saisis (ou calculés, nombre pair), surcoût retiré si la référence était virtuelle |
| Mémoire | RAM proposée ; réservation minimale sur l’hôte et contrôle de la part réservée | RAM installée |
| Disques | Disques virtuels arrondis, IOPS et Mo/s à garantir par le stockage (plafonds des disques cloud) | Nombre de disques, RAID, pénalité d’écriture, réserve de reconstruction |
| Réseau | Cartes virtuelles | Cartes physiques |

## 5. Trois exemples chiffrés

Les exemples du dossier `examples` n’ont pas de profil propre : ils utilisent le profil de référence de leur rôle.

### Edge Internet (`Edge-Internet.json`, profil REF-EDGE)

180 000 messages par jour (120 000 entrants, 60 000 sortants, 75 Ko), croissance 20 %, 2 sites × 2 Edge, perte d’un serveur.

| Étape | Calcul | Résultat |
|---|---|---|
| Messages par jour et par serveur | 180 000 × 1,20 ÷ 3 | 72 000 |
| Débit de dimensionnement | 72 000 × 15 % ÷ 3 600 | 3,0 msg/s |
| File au pire moment | 180 (transit) + 72 000 (24 h de panne) | 72 180 messages, 5,2 Go |
| `mail.que` | 0,5 + 5,16 × 1,245 + 6,4 (un jour non récupéré) | 13,3 Go → volume de 20 Go |
| Processeur | (2,44 + 0,781 × 3 + 3,672 × 0,22 + 0,053 × 3 + 0,228 × 3 + 1,236 × 0,22) ÷ 100 × 2 × 1,24 | 0,17 cœur → 4 vCPU (minimum) à 4 % |
| Mémoire | max(2 713 Mo ÷ 72 %, 5 160 Mo ÷ 88 %) × 1,10, dont 180 × 63,5 Ko (transit) + 72 000 × 22 Ko (panne, déshydratée) | 6,3 Go → 8 Go |
| Disque de la file | (3,2 + 9,9) × 1,20 | 16 IOPS, 1,1 Mo/s en écriture |
| Réseau | Carte la plus chargée | 1,3 Mbit/s |
| Débit maximal, vidange | Processeur ; vidange plafonnée au débit mesuré (97,5 msg/s) | 89,4 msg/s reçus ; 24 h de panne vidées en 0,2 h |

### Mailbox relais sans boîtes (`Mailbox-Relay.json`, profil REF-MAILBOX)

170 000 messages par jour (100 000 entrants, 50 000 sortants de 75 Ko, 20 000 de relais applicatif de 40 Ko), croissance 20 %, 2 sites × 2 serveurs sans DAG, perte d’un site.

| Étape | Calcul | Résultat |
|---|---|---|
| Messages par jour et par serveur | 170 000 × 1,20 ÷ 2 | 102 000, 70,9 Ko en moyenne |
| Débit de dimensionnement | 102 000 × 15 % ÷ 3 600 | 4,25 msg/s |
| File au pire moment | 255 + 102 000 (panne) + 204 000 (Safety Net 2 jours) + 306 255 (copies shadow) | 612 510 messages, 41,4 Go |
| `mail.que` | 0,5 + 41,4 × 1,19 + 16,4 | 66,0 Go → volume de 90 Go (calculateur Microsoft : 55,2 Go) |
| Processeur | (3,63 + 3,189 × 4,25 + 3,702 × 0,29) ÷ 100 × 4 | 0,73 cœur → 4 vCPU (minimum) à 18 % |
| Mémoire | max(5 115 Mo ÷ 72 %, 16 585 Mo ÷ 88 %) × 1,10, dont 510 × 57,8 Ko (transit) + 204 000 × 20 Ko (panne et copies shadow, déshydratées ; mémoire au repos du profil : 12,2 Go, bases du labo déduites) | 20,2 Go → 24 Go |
| Disque de la file | (2,2 + 13,7) × 1,20 | 19 IOPS, 2,2 Mo/s en écriture |
| Réseau | Flux + copies shadow (2,6 Mbit/s dans chaque sens) | 5,3 Mbit/s |
| Débit maximal, vidange | Processeur ; vidange au coût déduit par analogie (0,36 % par msg/s) | 22,2 msg/s reçus ; 24 h de panne vidées en 0,15 h à 186 msg/s |

Avec une journalisation de tous les messages vers une archive externe, le même serveur traite 8,5 messages par seconde (4,25 reçus et 4,25 rapports). Il passe alors à 26 % de 4 vCPU, 24 Go de RAM, `mail.que` de 101 Go et un volume de 130 Go. Sans journalisation, le profil REF-EDGE donnerait 5 % de CPU au lieu de 18 % : un serveur Mailbox se dimensionne avec une calibration Mailbox.

### Edge à 2 millions de messages par jour, pointe mesurée (`Edge-2M-Pointe.json`, profil REF-EDGE)

Paramètres :
- 2 millions de messages par jour : 1,4 million entrants, 600 000 sortants, 75 Ko ;
- pointe mesurée de **300 000 messages par heure** pour l’organisation, pendant **2 heures** ;
- **10 heures ouvrées**, 15 % du trafic hors heures ouvrées ;
- croissance 20 %, 2 sites × 2 Edge, perte d’un serveur ;
- panne du saut suivant de 4 heures en journée.

| Étape | Calcul | Résultat |
|---|---|---|
| Messages par jour et par serveur | 2 000 000 × 1,20 ÷ 3 | 800 000 |
| Part de l’heure de pointe | 300 000 ÷ 2 000 000 | 15 % |
| Débit de dimensionnement | 800 000 × 15 % ÷ 3 600 | 33,3 msg/s (120 000 msg/h) |
| Débit moyen des heures ouvrées | 800 000 × 85 % ÷ 10 ÷ 3 600 | 18,9 msg/s (68 000 msg/h) |
| Panne de 4 h | 2 h de pointe à 15 % + 2 h à (85 − 30) ÷ 8 = 6,9 % | 0,44 jour, 350 000 messages |
| `mail.que` | 0,5 + 25,2 × 1,245 + 71,2 (un jour non récupéré) | 103 Go → volume de 140 Go |
| Processeur | (2,44 + 0,781 × 33,3 + 3,672 × 2,44 + 0,053 × 33,3 + 0,228 × 33,3 + 1,236 × 2,44) ÷ 100 × 2 × 1,24 | 1,23 cœur → 4 vCPU à 31 % |
| Mémoire | max(8 880 Mo ÷ 72 %, 11 301 Mo ÷ 88 %) × 1,10, dont 2 000 × 63,5 Ko (transit) + 350 000 × 22 Ko (panne, déshydratée) | 13,8 Go → 16 Go |
| Disque de la file | (33,0 + 51,3) × 1,20 | 101 IOPS, 11,6 Mo/s en écriture |
| Débit maximal, vidange | Processeur ; vidange plafonnée au débit mesuré (97,5 msg/s) | 89,4 msg/s reçus ; 4 h de panne vidées en 1,0 h |

Répartis uniformément sur 24 heures, ces 2 millions de messages ne feraient que 9,3 msg/s par serveur. Ici, la pointe de deux heures fixe le processeur, et la panne en journée fixe la mémoire et la file. Avec 16 Go, 168 000 messages de la panne restent complets en mémoire ; au-delà, EdgeTransport atteint 72 % de la RAM avant la mémoire totale, et le rapport annonce des refus temporaires pendant la déshydratation. Le rapport signale aussi que les 33 sessions SMTP par seconde dépassent 1,5 fois celles mesurées sur REF-EDGE : leur coût est extrapolé.

## 6. Mesures du labo

| | REF-EDGE | REF-MAILBOX |
|---|---|---|
| Serveur | Azure D2s_v5, 2 vCPU, 8 Go, Exchange SE, agents antispam | Azure D4s_v5, 4 vCPU, 16 Go, Exchange SE, membre de DAG avec une base montée, agent anti-malware actif |
| CPU à vide | 2,44 % | 3,63 % |
| Par message/s | 0,78 % | 3,19 % |
| Par Mo/s | 3,67 % | 3,70 % |
| Par message/s et par règle Edge | 0,098 % (100 règles saturent à 8 msg/s) | non mesuré |
| Par session/s, par session TLS/s, par Mo/s en TLS | 0,053 %, 0,228 %, 1,24 % | non mesuré |
| Par rapport de journal/s | — | 1,89 % |
| Mémoire par message en file | 63,5 Ko complet (66 Ko jusqu’à 72 000 messages le 7 octobre) ; 22 Ko déshydraté (195 898 messages, cinq déshydratations à 88 % de mémoire utilisée, aucun refus) | 58 Ko complet ; 20 Ko déshydraté par analogie |
| Réception seule, saut suivant coupé | 54 msg/s de 75 Ko : 45 % de CPU (rien à relayer) | non mesuré |
| Croissance de `mail.que` | facteur ESE 1,245 ; 1,2 à 1,6 Mo par Mo traité sans récupération | 1,19 Mo par Mo stocké (Safety Net 8 jours) |
| Envois SMTP par message | 1 | 2 (saut suivant et copie shadow), 3 avec journalisation |
| Vidange | 0,11 % de CPU par msg/s renvoyé, 1,05 E/S par message ; 195 896 messages déshydratés vidés à 97,5 msg/s (13 % de CPU), rythme donné par les serveurs Mailbox | 6 000 messages en moins de 30 s ; coût par analogie (0,36 % par msg/s) |
| Mémoire utilisée au repos | 3,5 Go | 13,1 Go mesurés, dont 0,9 Go pour les bases de boîtes du labo (4 Store workers, cache ESE de 512 Mo) : 12,2 Go dans le profil de référence |

Profils de référence : `data\Reference-Edge.json` (REF-EDGE) et `data\Reference-Mailbox.json` (REF-MAILBOX). Le premier profil d’REF-EDGE, à 75 Ko seulement, reste dans `examples\Calibration-Reference-Edge.json` comme exemple de profil à importer.

## 7. Profil de référence, ajustements ou calibration

| Contexte du projet | Profil utilisé | Résultat |
|---|---|---|
| Aucun serveur Exchange à mesurer (nouvelle organisation, migration depuis une autre messagerie) | **Profil de référence** du rôle, livré avec l’outil : REF-EDGE pour un Edge, REF-MAILBOX pour un serveur Mailbox | Dimensionnement générique, fondé sur les mesures du labo ; le rapport l’indique |
| Contexte connu, mais pas de mesure possible | Profil de référence **ajusté** : processeur (%) pour des processeurs plus lents ou plus rapides, des agents ou un antivirus en plus ; E/S (%) pour le stockage ; mémoire au repos (Go) d’un serveur du client. Le SPECint_rate2017 par cœur de la cible ajuste aussi le processeur quand il est connu des deux côtés | Dimensionnement générique adapté au client ; chaque ajustement figure dans le rapport |
| Un serveur Exchange du client peut être mesuré | **Profil mesuré** sur ce serveur (étapes ci-dessous), importé dans la fenêtre (« Importer un profil… ») ou passé avec `-Calibration` ; les ajustements s’appliquent encore | Dimensionnement sur les mesures du client |

Les profils de référence donnent un ordre de grandeur sur des VM Azure. Pour mesurer un serveur du client, le choisir au plus près de la cible : même taille de VM ou même matériel, même version d’Exchange, mêmes agents (antispam, anti-malware, règles, journalisation).

### Mesurer un serveur du client

1. Sur le serveur, `Measure-TransportLoad.ps1` collecte les compteurs pendant chaque palier. Sur un autre ordinateur, `Send-TransportTestLoad.ps1` envoie la charge.
2. Un palier à vide, puis au moins trois débits, le plus élevé proche du débit de dimensionnement.
3. Paliers de facteurs selon ce qui différera de la référence : tailles (pièces jointes), règles de transport, sessions et TLS, journalisation (règle de journal activée entre deux paliers).
4. Un palier backlog : saut suivant coupé, nombre connu de messages, pour la mémoire par message en file et le facteur ESE. Il faut assez de messages pour faire grossir `mail.que` de plusieurs incréments ; pour mesurer la mémoire d’un message déshydraté, assez pour amener la mémoire utilisée à 88 % (environ 70 000 messages de 75 Ko sur 8 Go). Puis un palier `Drain` pendant la vidange : CPU et E/S d’un message renvoyé.
5. Un palier de validation (mélange de tailles), gardé hors de l’ajustement.
6. `Measure-TransportLoad.ps1 -Analyze` écrit le profil. On l’importe ensuite dans la fenêtre ou on le passe avec `-Calibration`.

Le rapport signale :
- un modèle peu linéaire (R² < 0,8) ;
- un débit de dimensionnement au-delà de 1,5 × le débit mesuré ;
- une taille, des règles ou des sessions hors de la plage mesurée ;
- un profil mesuré sur l’autre rôle.

## 8. Importer le trafic réel

[Exchange Log Report](https://github.com/Nico77600/ExchangeLogReport), en rapport détaillé sur au moins sept jours, donne les flux sans estimation :

```powershell
.\Invoke-ExchangeLogReport.ps1 -Range Last7Days -ReportType Detailed -NoCollect
.\Invoke-TransportSizer.ps1 -LogReport D:\ExchangeLogReport\reports -SaveScenario .\Mesure.json
```

Dans la fenêtre, le bouton « Importer… » au-dessus des flux fait la même chose. L’import fournit :
- **sens des messages** : « Incoming » donne un flux entrant ; « Originating » donne un flux sortant si au moins un destinataire a été envoyé en SMTP, interne sinon. Sur un Edge, tout message « Originating » est sortant ;
- **messages par jour** : jour moyen de la période, ou jour complet le plus chargé ;
- **taille moyenne par sens** ;
- **transmissions** : nombre de domaines de destination par message sortant ;
- **débit de pointe mesuré** : messages de l’heure la plus chargée de la période (msg/h, organisation), et sa part du jour ;
- **journée de trafic**, sur au moins une journée :
  - heures ouvrées = heures de la journée au-dessus de la moyenne horaire ;
  - part du trafic en dehors de ces heures ;
  - durée de la pointe = heures à 80 % ou plus de l’heure la plus chargée ;
- **messages par session et part de TLS**, lus sur les sessions reçues du service de transport.

Ne sont pas comptés :
- les messages refusés pendant la session SMTP ;
- les rapports de journal, que la journalisation du scénario calcule elle-même.

## 9. Limites connues

- **Mémoire de base Mailbox** : REF-MAILBOX porte quatre copies de bases. Leur mémoire mesurée (Store workers, cache ESE compris : 0,9 Go) est déduite du profil de référence. Restent 12,2 Go au repos, dont IIS (2,9 Go) et l’indexation (0,8 Go), présents sur tout serveur Mailbox. Si la mémoire au repos d’un serveur du client est connue, la saisir dans les ajustements. Le collecteur mesure désormais la mémoire des Store workers et la déduit lui-même.
- **Facteurs Mailbox non isolés** : sur REF-MAILBOX, ni les règles de transport, ni les sessions, ni TLS, ni la part de l’agent anti-malware n’ont été mesurés à part. Leur coût est compris dans le coût par message, aux réglages du labo.
- **Récupération de l’espace de `mail.que`** : mesurée sur un Edge, appliquée au rôle Mailbox par analogie (le rapport le signale).
- **Déshydratation et vidange sur Mailbox** : mesurées sur REF-EDGE, appliquées à la référence Mailbox par analogie (même processus EdgeTransport ; le rapport le signale). Les refus temporaires quand `PrivateBytes` est atteint avant `SystemMemory` sont déduits des seuils de Microsoft, pas observés.
- **Trafic Internet réel** : les profils viennent d’un trafic de test sans spam, sans connexions refusées ni destinataires inconnus. Sur un Edge Internet très exposé, le processeur réel peut être plus élevé : l’ajustement processeur (%) ou une calibration sur un Edge du client le prend en compte. À l’inverse, sans relais (saut suivant coupé), la réception de 54 msg/s n’a coûté que 45 % de 2 vCPU.
- **Vidange** : plafonnée au débit mesuré, qui dépend du saut suivant du labo.
- **SPECint** : la valeur du Xeon Platinum 8573C de la référence est estimée (8580, même génération). Sans valeur pour la cible, la même performance par cœur que la référence est supposée. Le SPECint mesure du calcul entier, pas exactement le travail d’un serveur de transport (beaucoup d’E/S réseau et disque) : c’est le meilleur comparatif publié, pas une mesure de transport.
- **Ratio vCPU** : la capacité garantie suppose que tous les vCPU de l’hôte travaillent en même temps. Un hôte peu chargé donne davantage, mais pas au moment d’une bascule ou d’une panne.
- **Labo Azure** : les profils viennent de VM Azure. Le stockage, le réseau et les processeurs d’une plateforme cliente peuvent changer les coûts, d’où l’intérêt de calibrer sur la cible.
