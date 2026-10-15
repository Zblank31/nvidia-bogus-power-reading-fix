# Ma carte NVIDIA est bloquée à 210 MHz : contournement d'une fausse lecture de puissance

> **Testé sur** : GALAX/KFA2 **RTX 3080 LHR 10 Go** achetée d'occasion (ex-minage) · Linux (Ubuntu 26.04) · pilote NVIDIA **615.71.09, modules noyau ouverts**.
> English: [README.en.md](README.en.md) · Vidéo : *(lien à venir)*
>
> ⚠️ **Un seul exemplaire de carte testé.** C'est un contournement qui désactive une protection, pas une réparation. Lis la section [« Ce que ça coûte »](#4-ce-que-ça-coûte-à-lire-avant-dappliquer).

## En bref

Tu as une carte NVIDIA (souvent une carte d'occasion, ex-minage) qui :

- affiche dans `nvidia-smi` une consommation absurde, **~400 W alors qu'elle ne fait rien** ;
- reste **bloquée à 210 MHz** dès qu'on lui demande du travail, avec la raison d'horloge **« SW Power Cap »** active ;
- garde son ventilateur **figé à 50 %** même à 25 °C ;
- et tout ça **avec plusieurs versions de pilote, plusieurs emplacements, et un BIOS d'origine** ?

Alors la carte *croit* consommer bien plus qu'elle ne le fait, et le firmware du pilote la bride en permanence. Voici un contournement qui tient en **une ligne** de configuration :

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
```

(à adapter avec **l'adresse PCI de ta carte** ; voir [le pas à pas](#2-le-correctif-pas-à-pas-linux)).

**Chez moi** : 210 → **1995 MHz** affichés, **3,4 → 19,4 TFLOPS** (×5,7), température maximale **44 °C** après deux minutes à fond, environ **160 W réels** mesurés à la prise.

## Sommaire

1. [Suis-je concerné ?](#1-suis-je-concerné-)
2. [Le correctif pas à pas (Linux)](#2-le-correctif-pas-à-pas-linux)
3. [Les résultats chez moi](#3-les-résultats-chez-moi)
4. [Ce que ça coûte (à lire avant d'appliquer)](#4-ce-que-ça-coûte-à-lire-avant-dappliquer)
5. [Si ça ne marche pas](#5-si-ça-ne-marche-pas)
6. [Comment je l'ai trouvé](#6-comment-je-lai-trouvé)
7. [Questions ouvertes](#7-questions-ouvertes)
8. [Participer](#8-participer)
9. [Avertissement, licence, crédits](#9-avertissement-licence-crédits)

## 1. Suis-je concerné ?

### Les symptômes (tous ensemble)

| Ce que tu observes | Chez moi |
|---|---|
| `nvidia-smi` annonce une grosse puissance **au repos** (0 % d'utilisation) | ~390-400 W au repos, ~420 W en charge |
| En charge, l'horloge reste au **minimum** (210 MHz) | 210 MHz, 3,4 TFLOPS contre ~25 pour ma carte jumelle saine |
| `nvidia-smi -q -d PERFORMANCE` : **SW Power Cap : Active** (`clocks_event_reasons.active` = `0x4`) | oui, en permanence sous charge |
| Ventilateur à **50 %** fixe, même à 25 °C | oui |
| Aucune cause thermique ou d'alimentation | 23-26 °C au repos, alimentation 1600 W |
| Même comportement avec d'autres pilotes / un autre emplacement | 3 versions de pilote, dock OCuLink puis carte mère |
| Le BIOS est celui d'origine | dump complet identique octet pour octet à la référence publiée pour ce modèle |

### Le test

```bash
./scripts/diagnostic.sh        # lecture seule ; à lancer au repos, puis pendant une charge (tools/gpuload 60)
```

Il affiche une ligne par carte et un verdict (« SUSPECT : lit 395 W alors que la carte est inactive », etc.). Il n'affiche ni numéro de série ni UUID : tu peux coller la sortie dans un ticket.

### Le test décisif : un wattmètre de prise

`nvidia-smi` peut se tromper, **pas la prise**. Compare :

- la puissance que `nvidia-smi` prête à la carte au repos ;
- la puissance de **tout le PC** (écran compris) mesurée à la prise, au repos.

Si `nvidia-smi` dit 395 W pour *une seule carte* alors que la prise montre 272 W pour *tout le PC*, la lecture est fausse (c'est mon cas). Si la prise confirme la consommation, **n'applique pas ce correctif** : tu cacherais un vrai problème (court-circuit, surchauffe…).

## 2. Le correctif pas à pas (Linux)

**Prérequis** : Linux, pilote NVIDIA récent avec firmware GSP (testé : 615.71.09, modules noyau **ouverts**), carte Volta ou plus récente, droits root, de préférence un wattmètre de prise.

**1. Trouve l'adresse PCI de ta carte** (ici `0000:09:00.0`) :

```bash
lspci -D -nn | grep -E "VGA|3D" | grep -i nvidia
# ou : ./scripts/apply-fix.sh --list
```

**2. Écris la configuration** (remplace l'adresse !) :

```bash
sudo tee /etc/modprobe.d/nvidia-bogus-power-fix.conf <<'EOF'
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
EOF
```

Les guillemets, le préfixe `pci=`, les `;` (y compris le dernier) comptent. Grâce à `pci=`, **seule cette carte** est concernée : ta carte saine, s'il y en a une, n'est pas touchée.

**3. Reconstruis l'initramfs** (sur beaucoup de distributions le module `nvidia` est chargé depuis l'initramfs, avant le montage du disque : sans cette étape l'option n'est pas vue au démarrage) :

```bash
sudo update-initramfs -u -k all     # Debian / Ubuntu
sudo dracut -f --regenerate-all     # Fedora / RHEL / openSUSE
sudo mkinitcpio -P                  # Arch
```

**4. Redémarre.**

**5. Vérifie** :

```bash
grep RegistryDwordsPerDevice /proc/driver/nvidia/params   # doit afficher ton adresse et RmPmgrPmuOverride=1
./scripts/verify.sh --bus 0000:09:00.0                    # petite charge + verdict
```

**Raccourci** : `sudo ./scripts/apply-fix.sh --bus 0000:09:00.0` fait les étapes 2 et 3 avec des garde-fous (vérifie l'adresse, demande confirmation, contrôle que `modprobe` voit l'option). Ajoute `--dry-run` pour voir ce qu'il ferait sans rien modifier.

**Retour arrière** : `sudo ./scripts/remove-fix.sh`, puis redémarre.

## 3. Les résultats chez moi

| | Avant | Après |
|---|---|---|
| Fréquence GPU affichée en charge | 210 MHz | **1995 MHz** (1965 MHz à 44 °C) |
| Fréquence mémoire en charge | 9251 MHz | 9251 MHz |
| Débit de calcul (FP32 FMA, `tools/gpuload`) | 3,4 TFLOPS | **19,4 TFLOPS** |
| Raison d'horloge | SW Power Cap | « Reliability » et « Board Limit » (bénignes) |
| Puissance lue par `nvidia-smi` | ~395 W (fausse) | `N/A` |
| Température (120 s à fond) | – | 31 → 44 °C, courbe qui s'aplatit |
| Prise (tout le PC + écran) | – | 329 W au repos → 515 W avec la carte à fond (**+186 W**) |

Les +186 W à la prise, avec un rendement d'alimentation d'environ 90 %, font **~150-170 W** pour la carte : la moitié de ses 320 W nominaux.

Ma carte jumelle saine (RTX 3080 Palit) donne 25 TFLOPS à 319 W. La carte corrigée en donne 77 % pour environ la moitié de la puissance. La raison est dans la section [Questions ouvertes](#7-questions-ouvertes) : **sa fréquence réelle n'est que de ~1335 MHz**, pas 1995.

Les mesures brutes sont dans [`data/`](data/), le détail de la recherche dans [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).

## 4. Ce que ça coûte (à lire avant d'appliquer)

La clé `RmPmgrPmuOverride=1` coupe, **pour cette carte**, la gestion de puissance faite par le PMU de la carte. Conséquences constatées :

1. **Plus de lecture de puissance** sur cette carte (`power.draw` = `N/A`) **et plus de limite de puissance** : plus rien ne la bride si elle se met à consommer trop. Chez moi elle reste à ~160 W, mais c'est à toi de surveiller (wattmètre).
2. **La lecture du ventilateur** (`fan.speed`) renvoie « Unknown Error ». Mes ventilateurs tournent (je les entends) et la température est normale, mais je ne peux plus lire ni régler leur vitesse avec `nvidia-smi`.
3. **Les protections matérielles** (ralentissement à 95 °C, arrêt à 98 °C) restent en place ; surveille quand même les températures les premières fois.
4. **N'applique pas** ce correctif si la consommation affichée est réelle (voir le test de la prise), ni si tu soupçonnes un vrai défaut électrique.
5. Pour **borner** la consommation, on peut a priori verrouiller les horloges (`nvidia-smi -lgc`) : je ne l'ai **pas encore testé** dans cet état.
6. Le réglage est lié à **l'adresse PCI** : si tu changes la carte de slot, il faut le refaire (`apply-fix.sh`).
7. Une **mise à jour du pilote** peut changer le sens de la clé : revérifie avec `verify.sh`.
8. Si la carte est encore **sous garantie**, un échange ou une réparation vaut mieux. Je n'ai pas ouvert la mienne : la cause matérielle est probable mais pas prouvée.

## 5. Si ça ne marche pas

- **`verify.sh` dit « NON : aucune option pour cette adresse »** : l'option n'est pas arrivée au module. Vérifie que `modprobe -c | grep RegistryDwordsPerDevice` affiche ta ligne, que l'adresse est la bonne (`lspci -D`), que l'initramfs a été reconstruit, que tu as bien redémarré.
- **L'option est reçue mais la carte reste à 210 MHz** : ta carte a sans doute une autre cause. Ouvre un ticket avec la sortie de `diagnostic.sh`.
- **N'utilise pas `RmPerfLimitsOverride=2`** (ni `170`) : ça fait disparaître « SW Power Cap » et on croit avoir gagné, mais la carte reste figée dans l'état de performance P8 (420 MHz, mémoire à 405 MHz) : 6,9 TFLOPS et une mémoire à l'arrêt. C'est un piège (détails dans [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md)).
- **Plus d'affichage / `nvidia-smi` en erreur** après redémarrage : ouvre une console texte (Ctrl+Alt+F3) ou démarre en mode de secours et supprime `/etc/modprobe.d/nvidia-bogus-power-fix.conf`, puis reconstruis l'initramfs.

## 6. Comment je l'ai trouvé

1. **Écarté** : la chauffe, l'alimentation, la RAM, les pilotes (trois versions), l'emplacement (dock OCuLink puis carte mère) et le BIOS : un dump complet de la flash est **identique octet pour octet** à la référence publiée pour ce modèle (base de BIOS de TechPowerUp), donc le vendeur n'avait pas laissé un BIOS de minage.
2. **Le coupable** : la raison d'horloge « SW Power Cap », déclenchée par une puissance lue de ~395 W, **constante** au repos alors que ma prise montre 272 W pour tout le PC.
3. **Hypothèse (non prouvée)** : un canal de mesure de courant de la carte est bloqué à fond d'échelle. Une chaîne de mesure avec un shunt de 5 mΩ, une pleine échelle de 163,84 mV et un rail de 12 V sature précisément à 163,84 mV ÷ 5 mΩ × 12 V ≈ **393 W**, soit la valeur constante observée au repos ; les autres canaux, normaux, ajoutent ~+29 W en charge. Un BIOS avec une limite de puissance plus haute n'aurait donc servi à rien.
4. **La piste logicielle** : le module `nvidia` accepte des « clés de registre » par carte (`NVreg_RegistryDwordsPerDevice`) transmises au firmware GSP de la carte. J'ai écrit un banc d'essai qui, pour chaque réglage, décharge puis recharge le pilote et mesure la carte (d'abord avec un redémarrage par essai, ~2 min, puis en rechargeant le pilote, ~45 s) : [`research/`](research/).
5. **Le résultat** : `RmPerfLimitsOverride=2` supprime le plafond mais fige la carte en P8 ; `RmPmgrPmuOverride=1` donne une carte qui monte et descend en fréquence normalement, sans plafond de puissance. C'était le premier réglage testé de la série rapide.

L'histoire complète, le tableau de tous les essais et ce qu'on sait (et ne sait pas) du mécanisme : [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).

## 7. Questions ouvertes

- **Fréquence réelle ~1335 MHz pour 1995 affichés.** Mesuré avec `tools/sondeclk` (compteur de cycles des SM rapporté à l'horloge globale) : ma carte saine délivre 1917-1938 MHz pour 1905-1920 affichés, la carte corrigée seulement ~1335 MHz pour 1995 affichés. Les résultats de calcul sont pourtant **identiques bit à bit** sur les deux cartes. Hypothèse : sans la gestion de puissance, la tension de la carte n'est plus pilotée correctement et l'horloge adaptative se limite à ce que la tension permet. Un balayage de `nvidia-smi -lgc` avec `sondeclk` dirait si c'est une limite tension/fréquence ou un diviseur.
- **D'autres cartes ?** RTX 3060 Ti / 3070 / 3080 / 3090 ex-minage, autres familles ? Seul mon exemplaire est testé.
- **Autres systèmes ?** Modules noyau propriétaires (non ouverts), autres versions de pilote, autres distributions : non testés. Sous Windows, je ne connais pas d'équivalent.
- **Quel canal est en cause ?** Inspecter la carte (soudures et pistes autour des shunts de mesure, traces d'un « shunt mod » par l'ancien propriétaire) permettrait de localiser le défaut. Je ne l'ai pas fait.

## 8. Participer

Si tu essaies, **dis-le-moi dans un ticket** (modèle « Rapport de compatibilité » dans [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/)) avec la sortie de `scripts/diagnostic.sh` avant et après. Les rapports négatifs sont aussi utiles que les positifs : c'est ce qui permettra de dire sur quelles cartes ça marche.

## 9. Avertissement, licence, crédits

- **À tes risques et périls.** Aucune garantie. Ce dépôt explique comment désactiver une fonction de protection d'une carte graphique : n'y touche que si tu as vérifié que la lecture de puissance est fausse et que tu surveilles ta machine.
- **Rien de NVIDIA n'est inclus** : ni firmware, ni BIOS, ni code du pilote. Les outils de mesure utilisent uniquement l'API publique du pilote. NVIDIA, GeForce et RTX sont des marques de NVIDIA Corporation ; ce projet n'est ni affilié ni approuvé par NVIDIA.
- **Licence** : [MIT](LICENSE).
- **Crédits** : le matériel, les mesures, les tests et les décisions sont de Zblank31 ; le diagnostic, les scripts et les outils de mesure ont été écrits avec l'assistant [Claude Code](https://claude.com/claude-code) (Anthropic).
