# Comment ça marche, et comment on l'a trouvé

Ce document détaille la recherche derrière le [README](../README.md) : ce qu'on a mesuré, ce qu'on suppose, les clés essayées (y compris celles qui ne servent à rien) et les pièges rencontrés en route.

## 1. La chaîne de cause à effet

```
canal de mesure de courant défaillant (hypothèse)
        │
        ▼
puissance lue ≈ 395 W en permanence, même au repos
        │
        ▼
la gestion de puissance de la carte voit « 395 W > limite de 320 W »
        │
        ▼
raison d'horloge « SW Power Cap » : horloge au minimum (210 MHz), ventilateur en mode « sécurité » (50 %)
```

Le correctif (`RmPmgrPmuOverride=1`) supprime l'étage du milieu pour cette carte : plus de gestion de puissance par le PMU, donc plus de lecture (`N/A`) et plus de plafond.

## 2. Ce qui est mesuré, ce qui est supposé

Mesuré :

- La lecture de puissance : 389 à 402 W au repos, 407 à 422 W en charge, avec une carte à 210 MHz (donc qui consomme en réalité très peu). La prise montrait 272 W pour tout le PC.
- « SW Power Cap » actif 100 % du temps en charge, 3,4 TFLOPS contre ~25 pour la carte jumelle saine.
- Le BIOS : un dump complet (999 424 octets) identique octet pour octet à la référence publiée pour ce modèle (SHA-256 `a562c94ac025992997238502edcfcb38f0e172483224882650ea56939c801f60`).
- Le même comportement avec trois versions de pilote, dans un dock OCuLink puis sur la carte mère.
- Avec la clé : `power.draw` vaut `N/A`, « SW Power Cap » disparaît, les états de performance sont dynamiques (P0, P2, P5, P8), on mesure 19,4 TFLOPS, la mémoire est à sa fréquence normale et les résultats de calcul sont identiques à ceux de la carte saine.

Supposé, sans preuve :

- L'origine est matérielle : un canal de mesure bloqué à fond d'échelle (≈ 393 W = 163,84 mV ÷ 5 mΩ × 12 V, la valeur constante observée). On n'a pas ouvert la carte.
- La clé coupe la gestion de puissance du PMU. C'est ce que suggèrent son nom et ses effets (la lecture de puissance disparaît, le plafond aussi), pas une documentation.
- (Corrigé) Nos premières mesures donnaient ~1335 MHz réels pour 1995 affichés. C'était un artefact du rechargement à chaud du pilote : après un vrai démarrage, la fréquence réelle (~1950 MHz) est égale à l'affichée.

## 3. Les clés de registre du pilote

Le module noyau `nvidia` accepte deux paramètres :

- `NVreg_RegistryDwords="CLÉ=valeur;CLÉ=valeur"` pour toutes les cartes ;
- `NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;CLÉ=valeur;CLÉ=valeur;"` pour une seule carte, désignée par son adresse PCI (domaine:bus:périphérique.fonction).

Ces clés sont transmises au pilote et au firmware de la carte. Elles ne sont pas documentées officiellement : on en trouve les noms dans le pilote (il y en a des centaines) et on en découvre l'effet en les essayant.

Deux leçons pratiques :

1. Le module est souvent chargé depuis l'initramfs, avant le montage du disque. Une ligne `options nvidia …` dans `/etc/modprobe.d` n'y est vue au démarrage que si l'initramfs est reconstruit (`update-initramfs -u`). Notre première série d'essais est tombée dans ce piège : le pilote ne voyait aucune option et tout paraissait sans effet. Il faut toujours vérifier que le pilote a reçu l'option : `grep RegistryDwordsPerDevice /proc/driver/nvidia/params`.
2. Un rechargement à chaud relit `/etc/modprobe.d`. Après `rmmod nvidia…`, un `modprobe nvidia` prend le fichier en compte sans toucher à l'initramfs. C'est ce qui permet d'essayer un réglage en 45 secondes sans redémarrer, au prix de fermer le bureau (voir [`research/`](../research/)).

## 4. Les essais

### Série 1 : invalide

Même plan que la série 2, mais sans reconstruire l'initramfs : le pilote n'a reçu aucune option. Rien à en tirer, sauf la leçon du §3.

### Série 2 : les clés « évidentes », une par redémarrage

| setting | received | load clock MHz | TFLOPS | power cap active % |
|---|---|---|---|---|
| (none) | - | 210 | 3.43 | 100 |
| `RmPerfRatedTdpLimit=0` | yes | 210 | 3.41 | 100 |
| `RmPerfRatedTdpLimit=1` | yes | 210 | 3.40 | 100 |
| `RMDisablePerfIntersect=1` | yes | 210 | 3.44 | 100 |
| `RmPerfLimitsOverride=85` | yes | 210 | 3.46 | 100 |
| `RmPerfLimitsOverride=170` | yes | 420 | 6.93 | 0 |
| `RMUseSwI2c=1` | yes | 210 | 3.42 | 100 |
| `RMUsePmuSwI2c=1` | yes | 210 | 3.42 | 100 |
| `RMForceLockedClocksMode=1` | yes | 210 | 3.42 | 100 |
| `RmPmgrIsenseCheckIgnore=1` | yes | 210 | 3.42 | 100 |

Seul `RmPerfLimitsOverride=170` change quelque chose, et ce n'est pas ce qu'on croit (voir §5).

### Série 3 : décortiquer `RmPerfLimitsOverride`

Les valeurs essayées se lisent comme des champs de 2 bits : 85 (`01010101`) met tous les champs à 1, 170 (`10101010`) les met tous à 2, et les autres valeurs isolent un champ ou en retirent un.

| setting | received | load clock MHz | TFLOPS | power cap active % | P-state |
|---|---|---|---|---|---|
| (none) | - | 210 | 3.43 | 100 | P2 |
| `RmPerfLimitsOverride=170` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=2` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=8` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=32` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=128` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=168` | yes | 210 | 3.42 | 100 | P2 |
| `RmPerfLimitsOverride=162` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=138` | yes | 420 | 6.90 | 0 | P8 |
| `RmPerfLimitsOverride=42` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RmPerfRatedTdpLimit=0` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RMDisablePerfIntersect=1` | yes | 420 | 6.93 | 0 | P8 |
| `RmPerfLimitsOverride=170;RMForceLockedClocksMode=1` | yes | 420 | 6.93 | 0 | P8 |

Conclusion : seul le champ des bits 0-1 compte, et seulement avec la valeur 2. Les autres champs, seuls ou ajoutés, ne changent rien, et les autres clés combinées avec non plus.

### Série rapide : le pilote rechargé entre deux essais

| réglage | reçu | fréquence affichée en charge | TFLOPS | plafond actif % | état |
|---|---|---|---|---|---|
| (aucun) | – | 210 MHz | 3,42 | 100 | P2 |
| `RmPmgrPmuOverride=1` | oui | 1995 MHz | 19,43 | 0 | P2 |

La série s'est arrêtée là (critère de succès : horloge ≥ 1000 MHz), donc les dix-sept autres réglages prévus n'ont pas été essayés. Données brutes : [`data/`](../data/).

## 5. Le piège `RmPerfLimitsOverride=2`

Avec `=2` (ou `=170`, `=162`, `=138`, `=42`), « SW Power Cap » disparaît, l'horloge passe de 210 à 420 MHz et le débit double (6,9 TFLOPS). On croit avoir trouvé. Mais :

- l'état de performance reste P8, le plus bas, même sous charge, et la mémoire reste à 405 MHz au lieu de 9251 MHz ;
- les clés d'états de performance qu'on comptait essayer par-dessus (`DisableDynamicPstate`, `RMForcePstate`, `PerfLevelSrc`, `RMDisablePStates`…) n'ont finalement pas été testées : la série s'est arrêtée au premier succès, avec une autre clé ;
- l'interprétation la plus plausible est que ce réglage ne « lève » pas le plafond, il arrête l'application des états de performance et des limites. La carte reste dans son état de démarrage. C'est pire qu'avant pour toute charge qui dépend de la mémoire (l'IA, par exemple).

## 6. La clé qui marche : `RmPmgrPmuOverride=1`

La carte retrouve un comportement normal : P0, P2, P5 ou P8 selon la charge, boost jusqu'à ~2 GHz affichés, mémoire à sa fréquence, et pas de plafond. En échange : plus de lecture de puissance (`N/A`), plus de limite de puissance, et une lecture du ventilateur en erreur.

Seule la valeur `1` a été essayée.

## 7. Fréquence affichée, fréquence réelle

`nvidia-smi` donne l'horloge demandée. `tools/sondeclk` mesure ce que les SM délivrent : il compte les cycles d'horloge (`clock64`) pendant un intervalle de l'horloge globale (`globaltimer`), dans un noyau de calcul qui occupe toute la carte.

| carte | affichée (nvidia-smi) | réelle (sondeclk) | TFLOPS | somme de contrôle des résultats |
|---|---|---|---|---|
| RTX 3080 Palit, saine (plafonnée à 319 W) | 1905-1920 MHz | 1917-1938 MHz | 25,0 | `c1a800a176215af3` |
| RTX 3080 LHR corrigée, après rechargement à chaud (artefact) | 1980-1995 MHz | 1335-1366 MHz | 19,4 | `c1a800a176215af3` |
| RTX 3080 LHR corrigée, après un vrai démarrage | 1950-1965 MHz | 1942-1950 MHz | ~27 | `c1a800a176215af3` |

Les deux cartes calculent exactement la même chose (même somme de contrôle) : la carte corrigée est plus lente, pas fausse. Données : [`data/sondeclk-both-gpus.txt`](../data/sondeclk-both-gpus.txt).

## 8. Puissance à la prise

| état | PC entier + écran |
|---|---|
| repos (deux cartes en P8, bureau ouvert) | 283 W |
| carte corrigée à fond (~27 TFLOPS), 75 s | 668 W |

Les 385 W de plus au mur font 330 à 345 W pour la carte (rendement ~90 %, un cœur du processeur occupé par le test), soit sa puissance nominale. Cela donne environ 80 GFLOPS/W, comme la carte saine (25 TFLOPS à 319 W). (Une première mesure à 515 W, à 1335 MHz réels, date de l'artefact du rechargement à chaud.)

## 9. Reproduire et aller plus loin

- Mesurer : `tools/gpuload` (charge), `tools/sondeclk` (fréquence réelle), `tools/charge_longue.sh` (charge surveillée avec coupure en température). Pas besoin du toolkit CUDA, un compilateur C suffit (`make -C tools`).
- Essayer d'autres clés : `research/reload-trials.sh`. Lis son avertissement avant : il ferme le bureau.
- Pistes non explorées : les clés dont le nom évoque l'étalonnage des capteurs de courant (`RmPmgrIsense…Override`), un balayage de `nvidia-smi -lgc` avec `sondeclk`, la mesure de la tension du cœur, et l'inspection de la carte autour des shunts de mesure (soudures, pistes, traces d'un « shunt mod » de l'ancien propriétaire).
