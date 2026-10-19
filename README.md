<!-- Lien de la vidéo : à ajouter ici (et dans README.en.md) quand elle sera en ligne. -->
# Carte NVIDIA bloquée à 210 MHz : un contournement

J'ai acheté d'occasion une GALAX RTX 3080 LHR de 10 Go qui avait servi au minage. Inutilisable : `nvidia-smi` lui prêtait 400 W alors qu'elle ne faisait rien, et dès qu'on lui donnait du travail elle restait collée à 210 MHz. Ce dépôt raconte ce qu'on a trouvé, comment on l'a contournée avec une seule ligne de configuration, et ce que ça coûte.

> Un seul exemplaire testé : Linux (Ubuntu 26.04), pilote NVIDIA 615.71.09, modules noyau ouverts.
> Ce n'est pas une réparation : le contournement désactive une protection. Lis [« Ce que ça coûte »](#4-ce-que-ça-coûte) avant de l'appliquer.
>
> English version: [README.en.md](README.en.md)

> Précision importante : sans gestion de puissance, le ventilateur n'est plus régulé. Chez moi, à fond, la carte consomme environ 330 W (sa puissance nominale) et monte à 68 °C en 75 s avec un bon flux d'air, mais elle était montée à 80 °C quand elle était mal placée. Assure-toi qu'elle est bien ventilée et surveille sa température les premières fois.

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

Chez moi, la carte passe de 210 à environ 1950 MHz et de 3,4 à environ 27 TFLOPS (×8). À fond, elle consomme environ 330 W d'après la prise, soit sa puissance nominale, et sa température plafonne vers 68 °C avec un bon flux d'air.

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
| Fréquence GPU en charge (affichée = réelle) | 210 MHz | ~1950 MHz |
| Fréquence mémoire en charge | 9251 MHz | 9251 MHz |
| Débit de calcul (FP32 FMA, `tools/gpuload`) | 3,4 TFLOPS | ~27 TFLOPS |
| Raison d'horloge | SW Power Cap | « Reliability » et « Board Limit » (bénignes) |
| Puissance lue par `nvidia-smi` | ~395 W (fausse) | `N/A` |
| Température (75 s à fond, bon flux d'air) | | 38 → 68 °C, la courbe s'aplatit (80 °C atteints avec un mauvais placement) |
| Prise (tout le PC + écran) | | 283 W au repos, 668 W avec la carte à fond (+385 W) |

Avec un rendement d'alimentation d'environ 90 %, ces 385 W de plus à la prise font 330 à 345 W pour la carte (un cœur du processeur est aussi occupé par le test), soit sa puissance nominale de 320 W.

Ma carte jumelle saine (une RTX 3080 Palit) fait 25 TFLOPS à 319 W, plafonnée par sa limite de puissance. La carte corrigée n'a plus de limite : elle va un peu plus vite (~27 TFLOPS) pour la même consommation.

Les mesures brutes sont dans [`data/`](data/) et le détail de la recherche dans [`docs/comment-ca-marche.md`](docs/comment-ca-marche.md).

### Brider la fréquence par sécurité

Sans limite de puissance, la seule chose qui tient la carte, c'est ton flux d'air. Si le boîtier change ou si un ventilateur lâche, rien ne la freine avant les protections à 95 °C. J'ai donc plafonné la fréquence, ce qui ne touche pas au correctif :

```bash
sudo nvidia-smi -i 0 -lgc 210,1500     # essai ; pour annuler : sudo nvidia-smi -i 0 -rgc
```

Chez moi, avec 1500 MHz au lieu de ~1950 :

| | Libre (~1950 MHz) | Bridé (1500 MHz) |
|---|---|---|
| Débit de calcul | ~27 TFLOPS | 18 à 22 TFLOPS |
| Température après 75 s à fond | 68 °C | 42 à 51 °C |
| Prise (tout le PC + écran, repos à 283 W) | 668 W | 500 W |
| Carte seule (estimation, rendement ~90 %) | 330 à 345 W | 190 à 200 W |

On perd environ un quart du débit, mais la consommation baisse de 40 % et la carte chauffe une vingtaine de degrés de moins : la tension baisse avec la fréquence. Les TFLOPS varient d'une passe à l'autre (18,4 à 21,8 chez moi) et je n'ai pas compris pourquoi.

Le verrou saute au redémarrage et quand on recharge le pilote. Pour le remettre à chaque démarrage, `scripts/clock-cap.sh` installe un petit service systemd :

```bash
sudo ./scripts/clock-cap.sh --bus 0000:09:00.0 --max 1500    # avec --dry-run, il montre l'unité sans rien écrire
sudo ./scripts/clock-cap.sh --remove                         # pour l'enlever
```

Comme le correctif, il est lié à l'adresse PCI : si tu changes la carte d'emplacement, refais la commande.

## 4. Ce que ça coûte

La clé `RmPmgrPmuOverride=1` coupe, pour cette carte, la gestion de puissance que fait son PMU. Voilà ce que j'ai constaté :

1. Plus de lecture de puissance (`power.draw` vaut `N/A`) et plus de limite de puissance : rien ne la bride si elle se met à trop consommer. Chez moi elle va au bout de sa puissance nominale, autour de 330 W, et c'est à toi de surveiller, avec un wattmètre.
2. La lecture du ventilateur (`fan.speed`) renvoie « Unknown Error ». Mes ventilateurs tournent (je les entends) et la température est normale, mais je ne peux plus lire ni régler leur vitesse avec `nvidia-smi`.
3. Les protections matérielles (ralentissement à 95 °C, arrêt à 98 °C) restent en place. Surveille quand même les températures les premières fois.
4. N'applique pas ce correctif si la consommation affichée est réelle (voir le test de la prise), ni si tu soupçonnes un vrai défaut électrique.
5. Pour borner la consommation et la chauffe, verrouille la fréquence maximale avec `nvidia-smi -lgc` : ça marche dans cet état, voir [« Brider la fréquence »](#brider-la-fréquence-par-sécurité).
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

- La fréquence réelle sur d'autres cartes ou d'autres pilotes. Chez moi, après un vrai démarrage, `tools/sondeclk` donne la même fréquence réelle que celle affichée (~1950 MHz). Attention : nos premières mesures, faites après un rechargement du pilote sans redémarrer, donnaient seulement ~1335 MHz pour 1995 affichés. C'était un artefact de ce rechargement à chaud : pour juger les fréquences, redémarre.
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
