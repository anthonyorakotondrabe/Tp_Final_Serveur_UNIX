# TP Final — Architecture d'un Serveur UNIX Complet
**Licence 3 Informatique — Génie logiciel et I.A**

---

## 1. Présentation du TP

Dans ce TP, j'ai conçu et implémenté un serveur de fichiers distribué en C sur Linux, en partant d'un modèle simple vers un daemon UNIX complet. Le travail couvre cinq modèles progressifs : serveur itératif, concurrence par `fork()`, multi-threading POSIX, multiplexage I/O avec `select()`, et enfin la daemonisation avec `syslog`. Le script `tp_server.sh` automatise la génération du code source, la compilation et les tests.

---

## 2. Guide de démarrage rapide

### Prérequis
```bash
# Vérifier que gcc, make et netcat sont disponibles
gcc --version && make --version && nc -h 2>/dev/null | head -1
```

### Étape 1 — Générer les sources et compiler
```bash
chmod +x tp_server.sh
./tp_server.sh build
```
Cela crée le dossier `tp_final/` avec tous les fichiers `.c`, `.h`, le `Makefile`, et produit le binaire `tp_final/server`.

### Étape 2 — Lancer un mode et le tester
Ouvrir **deux terminaux** :

```bash
# Terminal 1 — démarrer le serveur (exemple : mode 3, pthreads)
./tp_server.sh run 3

# Terminal 2 — envoyer un message de test
echo "Salama eh!" | nc 127.0.0.1 9996
# Réponse attendue : [Thread] Echo : Salama eh!
```

### Étape 3 — Tests automatiques complets
```bash
./tp_server.sh all    # build + tous les tests en chaîne
```

### Étape 4 — Arrêter tous les serveurs
```bash
./tp_server.sh stop
# ou Ctrl+C dans le terminal du serveur (SIGINT géré proprement)
```

| Commande | Port | Description |
|---|---|---|
| `./tp_server.sh run 1` | 9999 | Serveur itératif |
| `./tp_server.sh run 2` | 9997 | Serveur fork |
| `./tp_server.sh run 3` | 9996 | Serveur pthreads |
| `./tp_server.sh run 4` | 9995 | Serveur select() |
| `./tp_server.sh run 5` | 9996 | Daemon (mode silencieux) |

---

## 3. Architecture et choix techniques

### Structure des fichiers générés
```
tp_final/
├── src/
│   ├── server.c    # point d'entrée, les 5 modes en un seul fichier
│   ├── handler.c   # traitement des clients (itératif et thread)
│   ├── daemon.c    # double fork + setsid + pidfile
│   └── utils.c     # compteur thread-safe, afficher_statut()
├── include/
│   └── server.h    # constantes et prototypes partagés
├── Makefile
└── syslog.conf.example
```

### Partie 1 — Serveur itératif
Le serveur accepte une connexion à la fois. Le second client attend que le premier soit traité : c'est le comportement **bloquant** de `accept()` dans une boucle simple sans fork ni thread. Chaque réponse porte un numéro séquentiel `[Connexion #N] Echo : <message>`. Les erreurs de `read()`/`write()` sont gérées avec `perror()` sans quitter le serveur.

### Partie 2 — Concurrence par fork()
Après chaque `accept()`, je fais un `fork()`. Le fils ferme `listenfd` et traite le client ; le père ferme `connfd` et reboucle immédiatement, ce qui permet de servir plusieurs clients en parallèle. Un gestionnaire `SIGCHLD` appelle `waitpid(-1, NULL, WNOHANG)` en boucle pour éviter les processus zombies. Le compteur de connexions actives est partagé via un **fichier temporaire** (`/tmp/srv_connexions.cnt`) : c'est la solution IPC la plus simple quand les fils ont leur propre espace mémoire.

### Partie 3 — Multi-threading pthreads
Je remplace `fork()` par `pthread_create()`. Le descripteur `connfd` est transmis au thread via une **copie allouée par `malloc()`** : passer `&connfd` directement provoquerait une race condition car `connfd` peut changer dans la boucle principale avant que le thread ne le lise. Le thread libère cette copie avec `free()` en début de fonction. `pthread_detach()` libère les ressources automatiquement. Le compteur `connexions_actives` est protégé par un `pthread_mutex_t`. Un pool de 16 threads maximum refuse les connexions supplémentaires avec un message d'erreur.

**Comparaison fork vs threads sous charge de 8 clients :**

| Critère | fork() | pthreads |
|---|---|---|
| Mémoire (VmRSS) | ~3 Mo par fils (espace dupliqué) | ~0.5 Mo par thread (mémoire partagée) |
| Latence démarrage | Plus élevée (copie de l'espace mémoire) | Faible (création légère) |
| Partage de données | IPC nécessaire (fichier, pipe, shm) | Direct via variables globales + mutex |
| Isolation | Totale (crash d'un fils n'affecte pas les autres) | Partielle (un thread peut corrompre tout le processus) |

### Partie 4 — Multiplexage I/O avec select()
Un seul fil d'exécution surveille `listenfd` et tous les clients connectés dans une `fd_set`. `select()` est appelé avec un timeout de 5 secondes. Quand `read()` retourne 0, c'est une déconnexion propre : je retire le descripteur du tableau et le ferme. Le nombre de descripteurs surveillés est affiché après chaque itération.

**Réponses aux 4 questions select/poll :**
- **Limite de select() absente dans poll()** : `select()` est limité à `FD_SETSIZE` (1024) descripteurs. `poll()` utilise un tableau dynamique sans borne fixe.
- **Pourquoi FD_SETSIZE=1024 est un problème** : un serveur de production gérant 500+ clients simultanés atteint cette limite ; les nouvelles connexions sont refusées.
- **Quand préférer poll() à select()** : dès que le serveur gère plus de 100-200 connexions car `poll()` ne recopie pas la `fd_set` à chaque appel et n'a pas de limite de descripteurs.
- **Syscall recommandée pour C10K (10 000+ connexions)** : `epoll` (Linux) ou `kqueue` (BSD/macOS), qui notifient uniquement les descripteurs actifs au lieu de scanner tous les descripteurs à chaque appel.

### Partie 5 — Daemonisation et syslog
La fonction `daemonize()` suit la séquence standard : **1er fork** (le père quitte, le fils devient chef de session via `setsid()`), **2ème fork** (le premier fils quitte, le daemon définitif ne peut plus acquérir de terminal), puis `chdir("/")`, `umask(0)`, et redirection de `stdin/stdout/stderr` vers `/dev/null`. Le PID est écrit dans `/tmp/myserverd.pid` avec un verrou `F_WRLCK` pour détecter une double instance. Tous les `printf()` sont remplacés par `syslog()` avec les niveaux appropriés (`LOG_INFO`, `LOG_WARNING`, `LOG_ERR`).

Pour voir les logs en temps réel :
```bash
# Ajouter dans /etc/rsyslog.conf :
daemon.*    /var/log/myserverd.log
# Puis :
sudo systemctl restart rsyslog
sudo tail -f /var/log/myserverd.log
```

---

## 4. Conclusion — Quel modèle pour la production ?

Pour un service en production, je choisirais **pthreads avec un pool de threads fixe** (Partie 3) pour un serveur à charge modérée (< 1 000 connexions simultanées) : la mémoire partagée simplifie l'architecture, la latence est faible, et le pool empêche l'épuisement des ressources. Pour un très grand nombre de connexions (C10K), je passerais à un modèle **événementiel avec `epoll`**, comme nginx ou Redis, car il élimine le coût de création/destruction de threads et scale linéairement.

---

*Code compilé sans warning avec `gcc -Wall -Wextra -pthread` — testé sur Linux.*
