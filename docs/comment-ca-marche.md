# Comment ça marche, et comment on l'a trouvé

Ce document détaille la recherche derrière le [README](../README.md) : la chaîne de cause à effet, ce qui est **mesuré** et ce qui est seulement **supposé**, les clés essayées (celles qui ne marchent pas aussi), et les pièges rencontrés en route.

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
raison d'horloge « SW Power Cap » ──► horloge au minimum (210 MHz), ventilateur en mode « sécurité » (50 %)
```

Le correctif (`RmPmgrPmuOverride=1`) coupe l'étage du milieu **pour cette carte** : plus de gestion de puissance par le PMU, donc plus de lecture (N/A) et plus de plafond.

## 2. Ce qui est mesuré, ce qui est supposé

**Mesuré**

- Lecture de puissance : 389-402 W au repos, 407-422 W en charge, avec la carte à 210 MHz (donc consommant en réalité très peu). La prise montrait 272 W pour tout le PC.
- « SW Power Cap » actif 100 % du temps en charge ; 3,4 TFLOPS contre ~25 pour la carte jumelle saine.
- BIOS : dump complet (999 424 octets) identique octet pour octet à la référence publiée pour ce modèle (SHA-256 `a562c94ac025992997238502edcfcb38f0e172483224882650ea56939c801f60`).
- Même comportement avec trois versions de pilote, dans un dock OCuLink puis sur la carte mère.
- Avec la clé : `power.draw` = N/A, plus de « SW Power Cap », états de performance dynamiques (P0/P2/P5/P8), 19,4 TFLOPS, mémoire à sa fréquence normale, résultats de calcul identiques à ceux de la carte saine.

**Supposé (non prouvé)**

- *L'origine est matérielle* : un canal de mesure bloqué à fond d'échelle (≈ 393 W = 163,84 mV ÷ 5 mΩ × 12 V, la valeur constante observée). On n'a pas ouvert la carte.
- *La clé coupe la gestion de puissance du PMU* : c'est ce que suggèrent son nom et ses effets (la lecture de puissance disparaît, le plafond aussi), pas une documentation.
- *La fréquence réelle plus basse (~1335 MHz) vient d'une tension non gérée* : à vérifier.

## 3. Les clés de registre du pilote

Le module noyau `nvidia` accepte deux paramètres :

- `NVreg_RegistryDwords="CLÉ=valeur;CLÉ=valeur"` : pour **toutes** les cartes ;
- `NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;CLÉ=valeur;CLÉ=valeur;"` : pour **une** carte, désignée par son adresse PCI (domaine:bus:périphérique.fonction).

Les clés sont transmises au firmware GSP de la carte ; celles qu'il ne connaît pas sont ignorées sans erreur. Elles ne sont pas documentées officiellement : on les trouve par leur nom (le firmware en connaît des centaines) et par leur effet.

Deux enseignements pratiques :

1. **Le module est souvent chargé depuis l'initramfs**, avant le montage du disque. Un `options nvidia …` dans `/etc/modprobe.d` n'est alors vu au démarrage **que si l'initramfs est reconstruit** (`update-initramfs -u`). Ma première série d'essais était **invalide** pour cette raison : le pilote ne voyait aucune option et tout paraissait « sans effet ». Il faut donc toujours vérifier que le pilote a reçu l'option : `grep RegistryDwordsPerDevice /proc/driver/nvidia/params`.
2. **Un rechargement à chaud relit `/etc/modprobe.d`** : après `rmmod nvidia…`, un `modprobe nvidia` prend en compte le fichier sans toucher à l'initramfs. C'est ce qui permet d'essayer un réglage en ~45 s sans redémarrer (au prix de fermer le bureau : voir [`research/`](../research/)).

## 4. Les essais

### Série 1 : invalide

Même plan que la série 2, mais sans reconstruire l'initramfs : le pilote n'a reçu aucune option (colonne « reçu » = NON). Aucun enseignement, sauf celui du §3.

### Série 2 : clés « évidentes », une par redémarrage

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

La valeur se lit comme quatre champs de 2 bits (0 = défaut, 1 ou 2 = forcer un indicateur à 0 ou à 1, 3 = invalide).

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

Conclusion : **seul le champ des bits 0-1 compte**, et seulement avec la valeur 2. Les autres champs, seuls ou ajoutés, ne changent rien ; les autres clés combinées non plus.

### Série rapide : le pilote rechargé entre deux essais

| réglage | reçu | fréquence affichée en charge | TFLOPS | plafond actif % | état |
|---|---|---|---|---|---|
| (aucun) | – | 210 MHz | 3,42 | 100 | P2 |
| `RmPmgrPmuOverride=1` | oui | **1995 MHz** | **19,43** | 0 | P2 |

La série s'est arrêtée là (critère de succès : horloge ≥ 1000 MHz) : les dix-sept autres réglages prévus n'ont pas été essayés. Données brutes : [`data/`](../data/).

## 5. Le piège `RmPerfLimitsOverride=2`

Avec `=2` (ou `=170`, `=162`, `=138`, `=42`), « SW Power Cap » disparaît, l'horloge passe de 210 à 420 MHz et le débit double (6,9 TFLOPS) : on croit avoir trouvé. Mais :

- l'état de performance reste **P8** (le plus bas) **même sous charge** ; la mémoire reste à **405 MHz** au lieu de 9251 MHz ;
- les clés d'états de performance qu'on comptait essayer par-dessus (`DisableDynamicPstate`, `RMForcePstate`, `PerfLevelSrc`, `RMDisablePStates`, etc.) n'ont finalement pas été testées : la série s'est arrêtée au premier succès, avec une autre clé ;
- l'interprétation la plus plausible : ce réglage ne « lève » pas le plafond, il **arrête l'application des états de performance et des limites**. La carte reste dans son état de démarrage. C'est pire qu'avant pour toute charge dépendant de la mémoire (IA, par exemple).

## 6. La clé qui marche : `RmPmgrPmuOverride=1`

Observé : la carte retrouve un comportement normal (P0/P2/P5/P8 selon la charge, boost jusqu'à ~2 GHz affichés, mémoire à sa fréquence), sans plafond. Prix : plus de lecture de puissance (`N/A`), plus de limite de puissance, lecture du ventilateur en erreur.

Seule la valeur `1` a été essayée.

## 7. Fréquence affichée contre fréquence réelle

`nvidia-smi` donne l'horloge **demandée**. `tools/sondeclk` mesure ce que les SM **délivrent** : il compte les cycles d'horloge (`clock64`) pendant un intervalle de l'horloge globale (`globaltimer`), dans un noyau de calcul qui occupe toute la carte.

| carte | affichée (nvidia-smi) | réelle (sondeclk) | TFLOPS | somme de contrôle des résultats |
|---|---|---|---|---|
| RTX 3080 Palit, saine (plafonnée à 319 W) | 1905-1920 MHz | 1917-1938 MHz | 25,0 | `c1a800a176215af3` |
| RTX 3080 LHR corrigée | 1980-1995 MHz | **1335-1366 MHz** | 19,4 | `c1a800a176215af3` |

Les deux cartes calculent exactement la même chose (même somme de contrôle) : la carte corrigée est plus lente, pas fausse. Données : [`data/sondeclk-both-gpus.txt`](../data/sondeclk-both-gpus.txt).

## 8. Puissance à la prise

| état | PC entier + écran |
|---|---|
| repos (deux cartes en P8, un navigateur ouvert) | 329 W |
| carte corrigée à fond (19,3 TFLOPS) pendant 2 min | 515 W |

+186 W au mur ≈ **150-170 W** pour la carte (rendement de l'alimentation ~90 %, un cœur du processeur occupé par le test). Efficacité : ~115 GFLOPS/W contre ~78 pour la carte saine (25 TFLOPS à 319 W).

## 9. Reproduire, et aller plus loin

- Mesurer : `tools/gpuload` (charge), `tools/sondeclk` (fréquence réelle), `tools/charge_longue.sh` (charge surveillée avec coupure en température). Aucun toolkit CUDA : un compilateur C suffit (`make -C tools`).
- Essayer d'autres clés : `research/reload-trials.sh` (lire l'avertissement : il ferme le bureau).
- Pistes non explorées : les clés dont le nom évoque l'étalonnage des capteurs de courant (`RmPmgrIsense…Override`), un balayage de `nvidia-smi -lgc` avec `sondeclk`, la mesure de la tension du cœur, l'inspection matérielle autour des shunts de mesure (soudures, pistes, traces d'un « shunt mod » par l'ancien propriétaire).
