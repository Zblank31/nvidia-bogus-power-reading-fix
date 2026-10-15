<!-- Lien de la vidéo : à ajouter ici (et dans README.en.md) quand elle sera en ligne. -->
# Carte NVIDIA bloquée à 210 MHz : un contournement

J'ai acheté d'occasion une GALAX RTX 3080 LHR de 10 Go qui avait servi au minage. Inutilisable : `nvidia-smi` lui prêtait 400 W alors qu'elle ne faisait rien, et dès qu'on lui donnait du travail elle restait collée à 210 MHz. Ce dépôt raconte ce qu'on a trouvé, comment on l'a contournée avec une seule ligne de configuration, et ce que ça coûte.

> Un seul exemplaire testé : Linux (Ubuntu 26.04), pilote NVIDIA 615.71.09, modules noyau ouverts.
> Ce n'est pas une réparation : le contournement désactive une protection. Lis [« Ce que ça coûte »](#4-ce-que-ça-coûte) avant de l'appliquer.
>
> English version: [README.en.md](README.en.md)

## Le résumé

Si ta carte, souvent d'occasion et ex-minage :

- annonce une consommation absurde au repos, autour de 400 W ;
- reste à 210 MHz en charge, avec la raison d'horloge « SW Power Cap » active ;
- a son ventilateur figé à 50 % même à 25 °C ;
- et ne change pas de comportement avec un autre pilote, un autre emplacement ou le BIOS d'origine,

alors elle croit consommer bien plus qu'elle ne le fait, et le firmware la bride en permanence. La ligne suivante, à adapter avec l'adresse PCI de ta carte, coupe la gestion de puissance de cette carte, et d'elle seule :

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
```

Chez moi, la carte passe de 210 à 1995 MHz affichés et de 3,4 à 19,4 TFLOPS (×5,7). Elle monte à 44 °C au maximum après deux minutes à fond, et consomme environ 160 W d'après la prise.

## 1. Est-ce ton cas ?

Voilà ce que je voyais. Pour que ce dépôt te serve, il faut que tu retrouves l'ensemble.

| Ce qu'on observe | Chez moi |
|---|---|
| `nvidia-smi` annonce une grosse puissance au repos (0 % d'utilisation) | ~390-400 W au repos, ~420 W en charge |
| En charge, l'horloge reste au minimum (210 MHz) | 210 MHz, 3,4 TFLOPS contre ~25 pour ma carte jumelle saine |
| `nvidia-smi -q -d PERFORMANCE` : « SW Power Cap : Active » (`clocks_event_reasons.active` = `0x4`) | oui, en permanence sous charge |
| Ventilateur fixe à 50 %, même à 25 °C | oui |
| Ni chauffe ni alimentation en cause | 23-26 °C au repos, alimentation de 1600 W |
| Même comportement avec d'autres pilotes ou un autre emplacement | 3 versions de pilote, dock OCuLink puis carte mère |
| BIOS d'origine | dump complet identique octet pour octet à la référence publiée pour ce modèle |

Le script `./scripts/diagnostic.sh` fait le tour de ces points en lecture seule. Lance-le une fois au repos, puis une fois pendant une charge (`tools/gpuload 60` dans un autre terminal). Il n'affiche ni numéro de série ni UUID, tu peux donc coller sa sortie dans un ticket.

Le test qui tranche, c'est un wattmètre de prise. `nvidia-smi` peut se tromper, pas la prise. Compare ce que `nvidia-smi` prête à la carte au repos avec ce que tire tout le PC (écran compris) à la prise. Chez moi, 395 W annoncés pour la seule carte contre 272 W mesurés pour tout le PC : la lecture était fausse. Si la prise confirme la consommation, n'applique pas ce correctif, tu cacherais un vrai problème (court-circuit, surchauffe).

## 2. Appliquer le correctif

Il te faut Linux, un pilote NVIDIA récent avec firmware GSP (testé : 615.71.09, modules noyau ouverts), une carte Volta ou plus récente, les droits root, et de préférence un wattmètre de prise.

**1. L'adresse PCI de ta carte** (ici `0000:09:00.0`) :

```bash
lspci -D -nn | grep -E "VGA|3D" | grep -i nvidia
# ou : ./scripts/apply-fix.sh --list
```

**2. Le fichier de configuration** (remplace l'adresse) :

```bash
sudo tee /etc/modprobe.d/nvidia-bogus-power-fix.conf <<'EOF'
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
EOF
```

Les guillemets, le préfixe `pci=` et les points-virgules (le dernier compris) comptent. Grâce à `pci=`, seule cette carte est concernée : si tu en as une saine à côté, elle n'est pas touchée.

**3. L'initramfs.** Sur beaucoup de distributions, le module `nvidia` est chargé depuis l'initramfs, avant le montage du disque. Sans cette étape, l'option n'est pas vue au démarrage.

```bash
sudo update-initramfs -u -k all     # Debian / Ubuntu
sudo dracut -f --regenerate-all     # Fedora / RHEL / openSUSE
sudo mkinitcpio -P                  # Arch
```

**4. Redémarre.**

**5. Vérifie :**

```bash
grep RegistryDwordsPerDevice /proc/driver/nvidia/params   # doit afficher ton adresse et RmPmgrPmuOverride=1
./scripts/verify.sh --bus 0000:09:00.0                    # petite charge, puis verdict
```

Pour aller plus vite, `sudo ./scripts/apply-fix.sh --bus 0000:09:00.0` fait les étapes 2 et 3 avec des garde-fous : il vérifie l'adresse, demande confirmation et contrôle que `modprobe` comprend bien la ligne. Avec `--dry-run`, il montre ce qu'il ferait sans rien modifier.

Pour revenir en arrière : `sudo ./scripts/remove-fix.sh`, puis redémarre.

## 3. Ce que ça donne chez moi

| | Avant | Après |
|---|---|---|
| Fréquence GPU affichée en charge | 210 MHz | 1995 MHz (1965 MHz à 44 °C) |
| Fréquence mémoire en charge | 9251 MHz | 9251 MHz |
| Débit de calcul (FP32 FMA, `tools/gpuload`) | 3,4 TFLOPS | 19,4 TFLOPS |
| Raison d'horloge | SW Power Cap | « Reliability » et « Board Limit » (bénignes) |
| Puissance lue par `nvidia-smi` | ~395 W (fausse) | `N/A` |
| Température (120 s à fond) | | 31 → 44 °C, la courbe s'aplatit |
| Prise (tout le PC + écran) | | 329 W au repos, 515 W avec la carte à fond (+186 W) |

Avec un rendement d'alimentation d'environ 90 %, ces 186 W de plus à la prise font 150 à 170 W pour la carte, soit la moitié de ses 320 W nominaux.

Ma carte jumelle saine (une RTX 3080 Palit) fait 25 TFLOPS à 319 W. La carte corrigée en fait 77 %, pour à peu près la moitié de la puissance. L'écart a une explication curieuse, développée au [§7](#7-ce-quon-ne-sait-pas) : sa fréquence réelle n'est que de 1335 MHz environ, pas 1995.

Les mesures brutes sont dans [`data/`](data/) et le détail de la recherche dans [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).

## 4. Ce que ça coûte

La clé `RmPmgrPmuOverride=1` coupe, pour cette carte, la gestion de puissance que fait son PMU. Voilà ce que j'ai constaté :

1. Plus de lecture de puissance (`power.draw` vaut `N/A`) et plus de limite de puissance : rien ne la bride si elle se met à trop consommer. Chez moi elle reste autour de 160 W, mais c'est à toi de surveiller, avec un wattmètre.
2. La lecture du ventilateur (`fan.speed`) renvoie « Unknown Error ». Mes ventilateurs tournent (je les entends) et la température est normale, mais je ne peux plus lire ni régler leur vitesse avec `nvidia-smi`.
3. Les protections matérielles (ralentissement à 95 °C, arrêt à 98 °C) restent en place. Surveille quand même les températures les premières fois.
4. N'applique pas ce correctif si la consommation affichée est réelle (voir le test de la prise), ni si tu soupçonnes un vrai défaut électrique.
5. Pour borner la consommation, on peut sans doute verrouiller les horloges avec `nvidia-smi -lgc`. Je n'ai pas encore testé ça dans cet état.
6. Le réglage est lié à l'adresse PCI. Si tu changes la carte de slot, refais-le avec `apply-fix.sh`.
7. Une mise à jour du pilote peut changer le sens de la clé. Relance `verify.sh` après.
8. Si la carte est encore sous garantie, un échange ou une réparation vaut mieux. Je n'ai pas ouvert la mienne : une cause matérielle est probable, mais pas prouvée.

## 5. Si ça ne marche pas

- `verify.sh` affiche « NON : aucune option pour cette adresse ». L'option n'est pas arrivée jusqu'au module. Vérifie que `modprobe -c | grep RegistryDwordsPerDevice` affiche ta ligne, que l'adresse est la bonne (`lspci -D`), que l'initramfs a été reconstruit et que tu as redémarré.
- L'option est reçue mais la carte reste à 210 MHz. Elle a probablement une autre cause. Ouvre un ticket avec la sortie de `diagnostic.sh`.
- N'utilise pas `RmPerfLimitsOverride=2` (ni `170`). « SW Power Cap » disparaît et on croit avoir gagné, mais la carte reste figée dans l'état de performance P8 (420 MHz, mémoire à 405 MHz) : 6,9 TFLOPS et une mémoire à l'arrêt. C'est un piège, détaillé dans [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).
- Plus d'affichage, ou `nvidia-smi` en erreur après le redémarrage. Ouvre une console texte (Ctrl+Alt+F3) ou démarre en mode de secours, supprime `/etc/modprobe.d/nvidia-bogus-power-fix.conf`, puis reconstruis l'initramfs.

## 6. Comment on l'a trouvé

D'abord, on a écarté ce qui est classique : la chauffe, l'alimentation, la RAM, les pilotes (trois versions), l'emplacement (dock OCuLink puis carte mère) et le BIOS. Un dump complet de la flash est identique octet pour octet à la référence publiée pour ce modèle (base de BIOS de TechPowerUp) : le vendeur n'avait donc pas laissé un BIOS de minage.

Le coupable, c'est la raison d'horloge « SW Power Cap », déclenchée par une puissance lue de 395 W environ, constante, même au repos, alors que la prise montrait 272 W pour tout le PC.

On pense (sans l'avoir prouvé) qu'un canal de mesure du courant est bloqué à fond d'échelle. Avec un shunt de 5 mΩ, une pleine échelle de 163,84 mV et un rail de 12 V, une chaîne de mesure sature exactement à 163,84 mV ÷ 5 mΩ × 12 V, soit 393 W : c'est la valeur constante qu'on lit au repos. Les autres canaux, normaux, ajoutent environ 29 W en charge. Dans ce cas, un BIOS avec une limite de puissance plus haute n'aurait servi à rien.

Reste la piste logicielle. Le module `nvidia` accepte des « clés de registre » par carte (`NVreg_RegistryDwordsPerDevice`), transmises au firmware GSP de la carte. On a écrit un banc d'essai qui, pour chaque réglage, décharge puis recharge le pilote et mesure la carte : d'abord avec un redémarrage par essai (2 minutes l'un), puis en rechargeant le pilote (45 secondes). Il est dans [`research/`](research/).

`RmPerfLimitsOverride=2` supprime le plafond mais fige la carte en P8. `RmPmgrPmuOverride=1` donne une carte dont les fréquences montent et descendent normalement, sans plafond de puissance : c'était le premier réglage testé de la série rapide.

L'histoire complète, le tableau de tous les essais et ce qu'on sait du mécanisme : [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).

## 7. Ce qu'on ne sait pas

- La fréquence réelle. `tools/sondeclk` compte les cycles des SM pendant un intervalle de l'horloge globale. Ma carte saine délivre 1917-1938 MHz pour 1905-1920 affichés, mais la carte corrigée seulement 1335 MHz environ pour 1995 affichés. Les résultats de calcul sont pourtant identiques bit à bit sur les deux cartes. Notre hypothèse : sans la gestion de puissance, la tension n'est plus pilotée correctement et l'horloge adaptative se limite à ce que la tension permet. Un balayage de `nvidia-smi -lgc` avec `sondeclk` dirait si c'est une limite tension/fréquence ou un diviseur.
- Les autres cartes. RTX 3060 Ti, 3070, 3080, 3090 ex-minage, autres familles : seul mon exemplaire est testé.
- Les autres systèmes. Modules noyau propriétaires, autres versions du pilote, autres distributions : non testés. Sous Windows, on ne connaît pas d'équivalent.
- Le canal en cause. Inspecter la carte (soudures et pistes autour des shunts de mesure, traces d'un « shunt mod » de l'ancien propriétaire) permettrait de localiser le défaut. Je ne l'ai pas fait.

## 8. Participer

Si tu essaies, dis-le dans un ticket (modèle « Rapport de compatibilité » dans [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/)), avec la sortie de `scripts/diagnostic.sh` avant et après. Les échecs sont aussi utiles que les réussites : c'est comme ça qu'on saura sur quelles cartes ça marche.

## 9. Avertissement, licence, crédits

- À tes risques. Aucune garantie. Ce dépôt explique comment désactiver une protection d'une carte graphique : n'y touche que si tu as vérifié que la lecture de puissance est fausse, et surveille ta machine.
- Rien de NVIDIA n'est inclus : ni firmware, ni BIOS, ni code du pilote. Les outils de mesure n'utilisent que l'API publique du pilote. NVIDIA, GeForce et RTX sont des marques de NVIDIA Corporation, avec laquelle ce projet n'a aucun lien.
- Licence : [MIT](LICENSE).
- Crédits : rien de tout ça n'aurait pu être découvert sans [Claude Code](https://claude.com/claude-code) et la puissance du modèle Claude Sonnet 5.5 (Anthropic). L'analyse, les scripts, les outils de mesure et la documentation, c'est lui ; la carte, les mesures sur ma machine et les décisions, c'est moi.
