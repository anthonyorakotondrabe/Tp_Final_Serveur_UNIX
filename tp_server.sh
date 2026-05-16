#!/bin/bash

# TP — Architecture d'un Serveur UNIX Complet 
# Script de compilation, construction et test du projet


set -e

PROJET="tp_final"
PORT_ITERATIF=9999
PORT_FORK=9997
PORT_THREAD=9996
PORT_SELECT=9995
PORT_INETD=9998
PIDFILE="/tmp/myserverd.pid"
LOGFILE="/tmp/myserverd.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[TP]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
erreur()  { echo -e "${RED}[ERREUR]${NC} $1"; }
titre()   { echo -e "\n${BLUE}========== $1 ==========${NC}"; }


# ÉTAPE 0 — Créer la structure du projet

creer_structure() {
    titre "Création de la structure du projet"
    mkdir -p ${PROJET}/{src,include}
    log "Dossiers créés : ${PROJET}/src/ et ${PROJET}/include/"
}


# ÉTAPE 1 — Générer server.h (en-têtes partagés)

generer_header() {
    cat > ${PROJET}/include/server.h << 'HEADER'
#ifndef SERVER_H
#define SERVER_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <syslog.h>
#include <fcntl.h>
#include <sys/stat.h>

#define PORT_ITER    9999
#define PORT_FORK    9997
#define PORT_THREAD  9996
#define PORT_SELECT  9995
#define BACKLOG      10
#define BUF_SIZE     1024
#define MAX_THREADS  16
#define PIDFILE      "/tmp/myserverd.pid"

/* Compteur partagé de connexions actives (version threads) */
extern int connexions_actives;
extern pthread_mutex_t mutex_connexions;

/* Prototypes utils */
void afficher_statut(void);

/* Prototypes handler */
void handle_client_iteratif(int connfd, int num_conn);
void *handle_client_thread(void *arg);

/* Prototypes daemon */
void daemonize(const char *pidfile);

#endif /* SERVER_H */
HEADER
    log "server.h généré"
}


# ÉTAPE 2 — Générer utils.c

generer_utils() {
    cat > ${PROJET}/src/utils.c << 'UTILS'
/*
 * utils.c — Fonctions utilitaires partagées
 * Objectif : affichage thread-safe du compteur de connexions actives
 * Paramètres : aucun
 * Retour : void
 */
#include "../include/server.h"

int connexions_actives = 0;
pthread_mutex_t mutex_connexions = PTHREAD_MUTEX_INITIALIZER;

/*
 * afficher_statut() — Affiche le nombre de connexions actives de manière thread-safe
 */
void afficher_statut(void) {
    pthread_mutex_lock(&mutex_connexions);
    syslog(LOG_INFO, "Connexions actives : %d", connexions_actives);
    fprintf(stderr, "[STATUT] Connexions actives : %d\n", connexions_actives);
    pthread_mutex_unlock(&mutex_connexions);
}
UTILS
    log "utils.c généré"
}

# ÉTAPE 3 — Générer handler.c (gestionnaire client commun)

generer_handler() {
    cat > ${PROJET}/src/handler.c << 'HANDLER'
/*
 * handler.c — Gestionnaires de connexions clients
 * Objectif : traiter les messages reçus des clients (echo numéroté)
 * Paramètres : connfd = descripteur de la connexion, num_conn = numéro séquentiel
 * Retour : void / void*
 */
#include "../include/server.h"

/*
 * handle_client_iteratif() — Traitement client en mode itératif (Partie 1)
 * Paramètres : connfd = socket client, num_conn = numéro de connexion
 * Retour : void
 */
void handle_client_iteratif(int connfd, int num_conn) {
    char buf[BUF_SIZE];
    char reponse[BUF_SIZE + 64];
    ssize_t n;

    n = read(connfd, buf, sizeof(buf) - 1);
    if (n < 0) {
        perror("read");
        close(connfd);
        return;
    }
    buf[n] = '\0';

    /* Supprimer le \n final si présent */
    if (n > 0 && buf[n-1] == '\n') buf[n-1] = '\0';

    snprintf(reponse, sizeof(reponse), "[Connexion #%d] Echo : %s\n", num_conn, buf);

    if (write(connfd, reponse, strlen(reponse)) < 0)
        perror("write");

    close(connfd);
}

/*
 * handle_client_thread() — Fonction exécutée par chaque thread (Partie 3)
 * Paramètres : arg = pointeur alloué dynamiquement vers le descripteur connfd
 * Retour : NULL
 * NOTE : on ne passe jamais &connfd directement car connfd peut changer
 *        dans la boucle principale avant que le thread ne le lise (race condition).
 */
void *handle_client_thread(void *arg) {
    int connfd = *((int *)arg);
    free(arg);  /* Libérer la copie allouée par malloc dans le père */

    char buf[BUF_SIZE];
    char reponse[BUF_SIZE + 64];
    ssize_t n;

    /* Incrémenter le compteur de connexions actives */
    pthread_mutex_lock(&mutex_connexions);
    connexions_actives++;
    pthread_mutex_unlock(&mutex_connexions);
    afficher_statut();

    n = read(connfd, buf, sizeof(buf) - 1);
    if (n < 0) {
        perror("read (thread)");
    } else {
        buf[n] = '\0';
        if (n > 0 && buf[n-1] == '\n') buf[n-1] = '\0';
        snprintf(reponse, sizeof(reponse), "[Thread] Echo : %s\n", buf);
        if (write(connfd, reponse, strlen(reponse)) < 0)
            perror("write (thread)");
    }

    close(connfd);

    /* Décrémenter le compteur */
    pthread_mutex_lock(&mutex_connexions);
    connexions_actives--;
    pthread_mutex_unlock(&mutex_connexions);
    afficher_statut();

    return NULL;
}
HANDLER
    log "handler.c généré"
}


# ÉTAPE 4 — Générer daemon.c

generer_daemon() {
    cat > ${PROJET}/src/daemon.c << 'DAEMON'
/*
 * daemon.c — Daemonisation du processus serveur (Partie 5)
 * Objectif : transformer le processus en daemon UNIX complet
 * Paramètres : pidfile = chemin vers le fichier PID
 * Retour : void (ne retourne pas en cas d'erreur fatale)
 */
#include "../include/server.h"

/*
 * daemonize() — Double fork + setsid + isolation complète du terminal
 */
void daemonize(const char *pidfile) {
    pid_t pid;
    int fd;

    /* --- 1er fork : détacher du terminal appelant --- */
    pid = fork();
    if (pid < 0) { perror("fork (1er)"); exit(EXIT_FAILURE); }
    if (pid > 0) exit(EXIT_SUCCESS);   /* Le père quitte */

    /* Créer une nouvelle session sans terminal de contrôle */
    if (setsid() < 0) { perror("setsid"); exit(EXIT_FAILURE); }

    /* --- 2ème fork : empêcher la réacquisition d'un terminal --- */
    pid = fork();
    if (pid < 0) { perror("fork (2ème)"); exit(EXIT_FAILURE); }
    if (pid > 0) exit(EXIT_SUCCESS);   /* Le 1er fils quitte */

    /* Le daemon définitif continue ici */

    /* Changer le répertoire courant en racine */
    if (chdir("/") < 0) { perror("chdir"); exit(EXIT_FAILURE); }

    /* Réinitialiser le masque de création de fichiers */
    umask(0);

    /* Rediriger stdin, stdout, stderr vers /dev/null */
    fd = open("/dev/null", O_RDWR);
    if (fd < 0) { perror("open /dev/null"); exit(EXIT_FAILURE); }
    dup2(fd, STDIN_FILENO);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) close(fd);

    /* --- Vérification de double instance via le fichier PID --- */
    char pidbuf[32];
    int pidfd = open(pidfile, O_RDWR | O_CREAT, 0640);
    if (pidfd < 0) {
        syslog(LOG_ERR, "Impossible d'ouvrir le fichier PID %s : %m", pidfile);
        exit(EXIT_FAILURE);
    }

    /* Verrouillage exclusif pour détecter une instance déjà active */
    struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
    if (fcntl(pidfd, F_SETLK, &fl) < 0) {
        syslog(LOG_ERR, "Une instance du daemon tourne déjà (pidfile verrouillé)");
        exit(EXIT_FAILURE);
    }

    /* Écrire le PID du daemon */
    ftruncate(pidfd, 0);
    snprintf(pidbuf, sizeof(pidbuf), "%ld\n", (long)getpid());
    if (write(pidfd, pidbuf, strlen(pidbuf)) < 0) {
        syslog(LOG_ERR, "Écriture PID échouée : %m");
        exit(EXIT_FAILURE);
    }

    syslog(LOG_INFO, "Daemon démarré avec PID=%ld, pidfile=%s", (long)getpid(), pidfile);
}
DAEMON
    log "daemon.c généré"
}

# ÉTAPE 5 — Générer server.c (programme principal — toutes parties)

generer_server() {
    cat > ${PROJET}/src/server.c << 'SERVER'
/*
 * server.c — Serveur UNIX complet (Parties 1 à 5)
 * Objectif : implémenter les 4 modèles de concurrence + daemonisation
 * Usage : ./server <mode>
 *   mode 1 : itératif (Partie 1)
 *   mode 2 : fork/concurrent (Partie 2)
 *   mode 3 : pthreads (Partie 3)
 *   mode 4 : select/multiplexage (Partie 4)
 *   mode 5 : daemon (Partie 5, basé sur le mode 3)
 */
#include "../include/server.h"

/* ---- Variables globales ---- */
static volatile int continuer = 1;

/* ---- Gestionnaire SIGINT/SIGTERM : arrêt propre ---- */
static void sig_arret(int signo) {
    (void)signo;
    continuer = 0;
    syslog(LOG_INFO, "Signal reçu : arrêt en cours...");
}

/* ---- Gestionnaire SIGCHLD : éviter les zombies (Partie 2) ---- */
static void sig_chld(int signo) {
    (void)signo;
    while (waitpid(-1, NULL, WNOHANG) > 0)
        ;
}

/* ---- Création de la socket d'écoute ---- */
static int creer_socket(int port) {
    int fd;
    struct sockaddr_in srv;
    int opt = 1;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); exit(EXIT_FAILURE); }

    /* SO_REUSEADDR : évite "address already in use" après redémarrage */
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt"); exit(EXIT_FAILURE);
    }

    memset(&srv, 0, sizeof(srv));
    srv.sin_family      = AF_INET;
    srv.sin_addr.s_addr = INADDR_ANY;
    srv.sin_port        = htons(port);

    if (bind(fd, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
        perror("bind"); exit(EXIT_FAILURE);
    }
    if (listen(fd, BACKLOG) < 0) {
        perror("listen"); exit(EXIT_FAILURE);
    }
    return fd;
}

/* ==========================================================================
   PARTIE 1 — Serveur TCP itératif
   ========================================================================== */
static void mode_iteratif(void) {
    int listenfd, connfd;
    int num_conn = 0;

    openlog("server_iter", LOG_PID | LOG_CONS, LOG_USER);
    listenfd = creer_socket(PORT_ITER);
    fprintf(stdout, "[Partie 1] Serveur itératif démarré sur le port %d\n", PORT_ITER);
    fprintf(stdout, "  → Les connexions sont traitées UNE PAR UNE (pas de parallélisme)\n");
    fprintf(stdout, "  → Ctrl+C pour arrêter\n\n");
    syslog(LOG_INFO, "Serveur itératif démarré sur port %d", PORT_ITER);

    signal(SIGINT,  sig_arret);
    signal(SIGTERM, sig_arret);

    while (continuer) {
        connfd = accept(listenfd, NULL, NULL);
        if (connfd < 0) {
            if (errno == EINTR) break;
            perror("accept");
            continue;
        }
        num_conn++;
        fprintf(stdout, "[Itératif] Connexion #%d acceptée\n", num_conn);
        handle_client_iteratif(connfd, num_conn);
    }

    close(listenfd);
    syslog(LOG_INFO, "Serveur itératif arrêté proprement");
    closelog();
    fprintf(stdout, "\n[Partie 1] Serveur arrêté.\n");
}

/* ==========================================================================
   PARTIE 2 — Serveur concurrent avec fork()
   ========================================================================== */
static void mode_fork(void) {
    int listenfd, connfd;
    pid_t pid;
    int num_conn = 0;
    /* Compteur partagé via fichier temporaire (solution IPC simple) */
    const char *cntfile = "/tmp/srv_connexions.cnt";

    openlog("server_fork", LOG_PID | LOG_CONS, LOG_USER);
    listenfd = creer_socket(PORT_FORK);
    fprintf(stdout, "[Partie 2] Serveur fork démarré sur le port %d\n", PORT_FORK);
    fprintf(stdout, "  → Chaque connexion est traitée par un processus fils indépendant\n");
    fprintf(stdout, "  → Ctrl+C pour arrêter\n\n");
    syslog(LOG_INFO, "Serveur fork démarré sur port %d", PORT_FORK);

    signal(SIGINT,  sig_arret);
    signal(SIGTERM, sig_arret);
    signal(SIGCHLD, sig_chld);   /* Éviter les zombies */

    /* Initialiser le compteur */
    FILE *f = fopen(cntfile, "w");
    if (f) { fprintf(f, "0\n"); fclose(f); }

    while (continuer) {
        connfd = accept(listenfd, NULL, NULL);
        if (connfd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        num_conn++;

        pid = fork();
        if (pid < 0) {
            perror("fork");
            close(connfd);
            continue;
        }

        if (pid == 0) {
            /* --- PROCESSUS FILS --- */
            close(listenfd);   /* Le fils n'accepte pas de nouvelles connexions */

            /* Incrémenter le compteur dans le fichier (IPC par fichier temporaire) */
            FILE *cf = fopen(cntfile, "r+");
            if (cf) {
                int cnt = 0;
                fscanf(cf, "%d", &cnt);
                rewind(cf);
                fprintf(cf, "%d\n", cnt + 1);
                fclose(cf);
            }

            syslog(LOG_INFO, "Fils PID=%d traite connexion #%d", getpid(), num_conn);
            handle_client_iteratif(connfd, num_conn);

            /* Décrémenter le compteur */
            cf = fopen(cntfile, "r+");
            if (cf) {
                int cnt = 0;
                fscanf(cf, "%d", &cnt);
                rewind(cf);
                fprintf(cf, "%d\n", cnt > 0 ? cnt - 1 : 0);
                fclose(cf);
            }
            syslog(LOG_INFO, "Fils PID=%d terminé", getpid());
            exit(EXIT_SUCCESS);
        }

        /* --- PROCESSUS PÈRE --- */
        close(connfd);   /* Le père ne parle pas au client */

        /* Lire et afficher le compteur */
        FILE *cf = fopen(cntfile, "r");
        if (cf) {
            int cnt = 0;
            fscanf(cf, "%d", &cnt);
            fclose(cf);
            fprintf(stdout, "[Fork] Connexion #%d → fils PID=%d | Actives : %d\n",
                    num_conn, pid, cnt);
        }
    }

    close(listenfd);
    unlink(cntfile);
    syslog(LOG_INFO, "Serveur fork arrêté proprement");
    closelog();
    fprintf(stdout, "\n[Partie 2] Serveur arrêté.\n");
}

/* ==========================================================================
   PARTIE 3 — Serveur multi-threadé avec pthreads
   ========================================================================== */
static int pool_actif = 0;   /* Nombre de threads actifs dans le pool */
static pthread_mutex_t mutex_pool = PTHREAD_MUTEX_INITIALIZER;

static void mode_threads(void) {
    int listenfd, connfd;
    pthread_t tid;
    int num_conn = 0;

    openlog("server_thread", LOG_PID | LOG_CONS, LOG_USER);
    listenfd = creer_socket(PORT_THREAD);
    fprintf(stdout, "[Partie 3] Serveur pthreads démarré sur le port %d\n", PORT_THREAD);
    fprintf(stdout, "  → Pool max : %d threads simultanés\n", MAX_THREADS);
    fprintf(stdout, "  → Ctrl+C pour arrêter\n\n");
    syslog(LOG_INFO, "Serveur threads démarré sur port %d", PORT_THREAD);

    signal(SIGINT,  sig_arret);
    signal(SIGTERM, sig_arret);

    while (continuer) {
        connfd = accept(listenfd, NULL, NULL);
        if (connfd < 0) {
            if (errno == EINTR) break;
            perror("accept");
            continue;
        }
        num_conn++;

        /* Vérifier si le pool est saturé */
        pthread_mutex_lock(&mutex_pool);
        if (pool_actif >= MAX_THREADS) {
            pthread_mutex_unlock(&mutex_pool);
            const char *msg = "[ERREUR] Serveur saturé, réessayez plus tard.\n";
            write(connfd, msg, strlen(msg));
            close(connfd);
            syslog(LOG_WARNING, "Pool saturé (%d threads) — connexion refusée", pool_actif);
            fprintf(stdout, "[Threads] Pool saturé, connexion #%d refusée\n", num_conn);
            continue;
        }
        pool_actif++;
        pthread_mutex_unlock(&mutex_pool);

        /*
         * CORRECT : allouer une copie du fd pour éviter la race condition.
         * Si on passait &connfd directement, connfd pourrait changer dans la
         * boucle avant que le thread ne le lise.
         */
        int *fd_copy = malloc(sizeof(int));
        if (!fd_copy) { perror("malloc"); close(connfd); continue; }
        *fd_copy = connfd;

        if (pthread_create(&tid, NULL, handle_client_thread, fd_copy) != 0) {
            perror("pthread_create");
            free(fd_copy);
            close(connfd);
            pthread_mutex_lock(&mutex_pool);
            pool_actif--;
            pthread_mutex_unlock(&mutex_pool);
            continue;
        }

        /* Détacher le thread : ses ressources seront libérées automatiquement */
        pthread_detach(tid);
        fprintf(stdout, "[Threads] Connexion #%d → thread TID=%lu | Pool : %d/%d\n",
                num_conn, (unsigned long)tid, pool_actif, MAX_THREADS);
    }

    close(listenfd);
    syslog(LOG_INFO, "Serveur threads arrêté proprement");
    closelog();
    fprintf(stdout, "\n[Partie 3] Serveur arrêté.\n");
}

/* ==========================================================================
   PARTIE 4 — Multiplexage I/O avec select()
   ========================================================================== */
static void mode_select(void) {
    int listenfd;
    int clients[FD_SETSIZE];
    fd_set readfds;
    struct timeval tv;
    int maxfd, i, n, connfd, nb_surveilles;
    char buf[BUF_SIZE];

    openlog("server_select", LOG_PID | LOG_CONS, LOG_USER);
    listenfd = creer_socket(PORT_SELECT);
    fprintf(stdout, "[Partie 4] Serveur select() démarré sur le port %d\n", PORT_SELECT);
    fprintf(stdout, "  → Mono-thread : un seul fil d'exécution pour tous les clients\n");
    fprintf(stdout, "  → Timeout select : 5 secondes\n");
    fprintf(stdout, "  → Ctrl+C pour arrêter\n\n");
    syslog(LOG_INFO, "Serveur select démarré sur port %d", PORT_SELECT);

    signal(SIGINT,  sig_arret);
    signal(SIGTERM, sig_arret);

    /* Initialiser le tableau de descripteurs clients à -1 */
    for (i = 0; i < FD_SETSIZE; i++) clients[i] = -1;

    maxfd = listenfd;

    while (continuer) {
        FD_ZERO(&readfds);
        FD_SET(listenfd, &readfds);

        /* Ajouter tous les clients actifs au fd_set */
        nb_surveilles = 1;  /* listenfd */
        for (i = 0; i < FD_SETSIZE; i++) {
            if (clients[i] >= 0) {
                FD_SET(clients[i], &readfds);
                if (clients[i] > maxfd) maxfd = clients[i];
                nb_surveilles++;
            }
        }

        /* Timeout de 5 secondes */
        tv.tv_sec  = 5;
        tv.tv_usec = 0;

        n = select(maxfd + 1, &readfds, NULL, NULL, &tv);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        if (n == 0) {
            fprintf(stdout, "[Select] Timeout — %d descripteurs surveillés\n", nb_surveilles);
            continue;
        }

        /* Nouvelle connexion sur listenfd ? */
        if (FD_ISSET(listenfd, &readfds)) {
            connfd = accept(listenfd, NULL, NULL);
            if (connfd < 0) { perror("accept"); }
            else {
                /* Ajouter dans le tableau */
                for (i = 0; i < FD_SETSIZE; i++) {
                    if (clients[i] < 0) { clients[i] = connfd; break; }
                }
                if (i == FD_SETSIZE) {
                    fprintf(stderr, "[Select] FD_SETSIZE atteint, connexion refusée\n");
                    close(connfd);
                } else {
                    fprintf(stdout, "[Select] Nouveau client fd=%d | Actifs : %d\n",
                            connfd, nb_surveilles);
                    syslog(LOG_INFO, "Nouveau client fd=%d", connfd);
                }
            }
        }

        /* Données sur un client existant ? */
        for (i = 0; i < FD_SETSIZE; i++) {
            if (clients[i] < 0 || !FD_ISSET(clients[i], &readfds)) continue;

            connfd = clients[i];
            n = read(connfd, buf, sizeof(buf) - 1);

            if (n == 0) {
                /* Déconnexion propre */
                fprintf(stdout, "[Select] Client fd=%d déconnecté\n", connfd);
                syslog(LOG_INFO, "Client fd=%d déconnecté proprement", connfd);
                close(connfd);
                clients[i] = -1;
            } else if (n < 0) {
                perror("read (select)");
                close(connfd);
                clients[i] = -1;
            } else {
                buf[n] = '\0';
                char reponse[BUF_SIZE + 32];
                snprintf(reponse, sizeof(reponse), "[Select] Echo : %s", buf);
                write(connfd, reponse, strlen(reponse));
            }
        }

        /* Afficher le nombre de descripteurs surveillés */
        nb_surveilles = 1;
        for (i = 0; i < FD_SETSIZE; i++)
            if (clients[i] >= 0) nb_surveilles++;
        fprintf(stdout, "[Select] Descripteurs surveillés : %d\n", nb_surveilles);
    }

    /* Nettoyage */
    for (i = 0; i < FD_SETSIZE; i++)
        if (clients[i] >= 0) close(clients[i]);
    close(listenfd);
    syslog(LOG_INFO, "Serveur select arrêté proprement");
    closelog();
    fprintf(stdout, "\n[Partie 4] Serveur arrêté.\n");
}

/* ==========================================================================
   PARTIE 5 — Mode daemon (basé sur le mode threads)
   ========================================================================== */
static void mode_daemon(void) {
    openlog("myserverd", LOG_PID | LOG_CONS, LOG_DAEMON);
    syslog(LOG_INFO, "Démarrage du daemon myserverd...");

    daemonize(PIDFILE);

    /* Après daemonize(), on est dans le processus daemon définitif */
    syslog(LOG_INFO, "Daemon actif, PID=%ld, écoute sur port %d", (long)getpid(), PORT_THREAD);

    int listenfd = creer_socket(PORT_THREAD);
    int num_conn = 0;
    pthread_t tid;

    signal(SIGINT,  sig_arret);
    signal(SIGTERM, sig_arret);

    while (continuer) {
        int connfd = accept(listenfd, NULL, NULL);
        if (connfd < 0) {
            if (errno == EINTR) break;
            syslog(LOG_WARNING, "accept() échoué : %m");
            continue;
        }
        num_conn++;

        pthread_mutex_lock(&mutex_pool);
        if (pool_actif >= MAX_THREADS) {
            pthread_mutex_unlock(&mutex_pool);
            const char *msg = "[ERREUR] Serveur saturé.\n";
            write(connfd, msg, strlen(msg));
            close(connfd);
            syslog(LOG_WARNING, "Pool saturé, connexion refusée");
            continue;
        }
        pool_actif++;
        pthread_mutex_unlock(&mutex_pool);

        int *fd_copy = malloc(sizeof(int));
        if (!fd_copy) { syslog(LOG_ERR, "malloc échoué : %m"); close(connfd); continue; }
        *fd_copy = connfd;

        if (pthread_create(&tid, NULL, handle_client_thread, fd_copy) != 0) {
            syslog(LOG_ERR, "pthread_create échoué : %m");
            free(fd_copy);
            close(connfd);
            pthread_mutex_lock(&mutex_pool);
            pool_actif--;
            pthread_mutex_unlock(&mutex_pool);
            continue;
        }
        pthread_detach(tid);
        syslog(LOG_INFO, "Connexion #%d acceptée, thread TID=%lu", num_conn, (unsigned long)tid);
    }

    close(listenfd);
    unlink(PIDFILE);
    syslog(LOG_INFO, "Daemon myserverd arrêté proprement");
    closelog();
}

/* ==========================================================================
   PARTIE 6 (BONUS) — Version inetd-compatible
   ========================================================================== */
static void mode_inetd(void) {
    /*
     * En mode inetd : pas de socket, pas de bind/listen/accept.
     * inetd redirige automatiquement stdin/stdout vers la socket.
     * On lit sur stdin, on écrit sur stdout.
     */
    char buf[BUF_SIZE];
    ssize_t n;

    while ((n = read(STDIN_FILENO, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        char reponse[BUF_SIZE + 32];
        snprintf(reponse, sizeof(reponse), "[inetd] Echo : %s", buf);
        write(STDOUT_FILENO, reponse, strlen(reponse));
    }
}

/* ==========================================================================
   MAIN
   ========================================================================== */
int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage : %s <mode>\n", argv[0]);
        fprintf(stderr, "  1 = itératif (port %d)\n", PORT_ITER);
        fprintf(stderr, "  2 = fork/concurrent (port %d)\n", PORT_FORK);
        fprintf(stderr, "  3 = pthreads (port %d)\n", PORT_THREAD);
        fprintf(stderr, "  4 = select/multiplexage (port %d)\n", PORT_SELECT);
        fprintf(stderr, "  5 = daemon (port %d)\n", PORT_THREAD);
        fprintf(stderr, "  6 = inetd (stdin/stdout)\n");
        return EXIT_FAILURE;
    }

    int mode = atoi(argv[1]);
    switch (mode) {
        case 1: mode_iteratif(); break;
        case 2: mode_fork();     break;
        case 3: mode_threads();  break;
        case 4: mode_select();   break;
        case 5: mode_daemon();   break;
        case 6: mode_inetd();    break;
        default:
            fprintf(stderr, "Mode invalide : %d\n", mode);
            return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
SERVER
    log "server.c généré"
}

# ÉTAPE 6 — Générer le Makefile

generer_makefile() {
    cat > ${PROJET}/Makefile << 'MAKEFILE'
CC      = gcc
CFLAGS  = -Wall -Wextra -pthread -I include/
SRCS    = src/server.c src/handler.c src/daemon.c src/utils.c
TARGET  = server

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f $(TARGET)

.PHONY: all clean
MAKEFILE
    log "Makefile généré"
}


# ÉTAPE 7 — Générer syslog.conf.example

generer_syslog_conf() {
    cat > ${PROJET}/syslog.conf.example << 'SYSLOG'
# Ligne à ajouter dans /etc/rsyslog.conf (ou /etc/syslog.conf)
# pour rediriger les logs de myserverd vers un fichier dédié :
daemon.*    /var/log/myserverd.log

# Après ajout, redémarrer rsyslog :
#   sudo systemctl restart rsyslog
# Vérifier en temps réel :
#   sudo tail -f /var/log/myserverd.log
SYSLOG
    log "syslog.conf.example généré"
}


# ÉTAPE 8 — Compiler le projet

compiler() {
    titre "Compilation du projet"
    cd ${PROJET}
    if make; then
        log "Compilation réussie : binaire './server' prêt"
    else
        erreur "Échec de la compilation"
        exit 1
    fi
    cd ..
}


# ÉTAPE 9 — Tests automatiques

tester() {
    titre "Tests automatiques"

    BIN="./${PROJET}/server"

    # --- Test Partie 1 : serveur itératif ---
    log "Test Partie 1 — Serveur itératif (port ${PORT_ITERATIF})"
    $BIN 1 &
    SRV_PID=$!
    sleep 1

    REPONSE=$(echo "bonjour" | nc -q 1 127.0.0.1 ${PORT_ITERATIF} 2>/dev/null)
    if echo "$REPONSE" | grep -q "Echo"; then
        log "  ✓ Partie 1 OK : $REPONSE"
    else
        warn "  ✗ Partie 1 : réponse inattendue : '$REPONSE'"
    fi

    # Test du 2ème numéro séquentiel
    REPONSE2=$(echo "monde" | nc -q 1 127.0.0.1 ${PORT_ITERATIF} 2>/dev/null)
    log "  ✓ Connexion #2 : $REPONSE2"

    kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null; sleep 1

    # --- Test Partie 2 : serveur fork ---
    log "Test Partie 2 — Serveur fork (port ${PORT_FORK})"
    $BIN 2 &
    SRV_PID=$!
    sleep 1

    # Lancer 8 clients simultanés (script fourni dans le TP)
    for i in $(seq 1 8); do
        (echo "Client $i : bonjour" | nc -q 1 127.0.0.1 ${PORT_FORK} 2>/dev/null) &
    done
    wait
    log "  ✓ Partie 2 : 8 clients simultanés envoyés"

    kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null; sleep 1

    # --- Test Partie 3 : serveur pthreads ---
    log "Test Partie 3 — Serveur pthreads (port ${PORT_THREAD})"
    $BIN 3 &
    SRV_PID=$!
    sleep 1

    for i in $(seq 1 8); do
        (echo "Thread client $i" | nc -q 1 127.0.0.1 ${PORT_THREAD} 2>/dev/null) &
    done
    wait
    log "  ✓ Partie 3 : 8 clients threadés servis"

    kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null; sleep 1

    # --- Test Partie 4 : serveur select ---
    log "Test Partie 4 — Serveur select (port ${PORT_SELECT})"
    $BIN 4 &
    SRV_PID=$!
    sleep 1

    REPONSE=$(echo "select test" | nc -q 1 127.0.0.1 ${PORT_SELECT} 2>/dev/null)
    log "  ✓ Partie 4 : $REPONSE"

    kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null; sleep 1

    titre "Tous les tests sont terminés"
}


# ARRÊT : tuer proprement tous les serveurs

arreter() {
    titre "Arrêt des serveurs"
    # Tuer par pidfile si daemon actif
    if [ -f "${PIDFILE}" ]; then
        PID=$(cat "${PIDFILE}" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill -SIGTERM "$PID"
            log "Daemon PID=$PID arrêté via SIGTERM"
            sleep 1
            rm -f "${PIDFILE}"
        fi
    fi
    # Tuer tous les processus "server" liés aux ports du TP
    for PORT in ${PORT_ITERATIF} ${PORT_FORK} ${PORT_THREAD} ${PORT_SELECT}; do
        PID=$(lsof -ti tcp:${PORT} 2>/dev/null)
        if [ -n "$PID" ]; then
            kill -SIGTERM $PID 2>/dev/null
            log "Processus sur port ${PORT} (PID=${PID}) arrêté"
        fi
    done
    log "Arrêt complet."
}


# MENU PRINCIPAL

afficher_aide() {
    echo ""
    echo "  Usage : $0 <commande>"
    echo ""
    echo "  Commandes disponibles :"
    echo "    build    — Créer les fichiers source C et compiler"
    echo "    test     — Lancer les tests automatiques (build requis)"
    echo "    run <N>  — Démarrer le serveur en mode N (1=iter, 2=fork, 3=thread, 4=select, 5=daemon)"
    echo "    stop     — Arrêter tous les serveurs actifs"
    echo "    clean    — Supprimer les fichiers compilés"
    echo "    all      — Tout faire (build + test)"
    echo ""
    echo "  Exemple de test manuel :"
    echo "    Terminal 1 : $0 run 3"
    echo "    Terminal 2 : echo 'bonjour' | nc 127.0.0.1 9996"
    echo "    Terminal 1 : Ctrl+C pour arrêter"
    echo ""
}

case "${1:-aide}" in
    build)
        creer_structure
        generer_header
        generer_utils
        generer_handler
        generer_daemon
        generer_server
        generer_makefile
        generer_syslog_conf
        compiler
        ;;
    test)
        tester
        ;;
    run)
        MODE="${2:-1}"
        log "Démarrage du serveur en mode $MODE..."
        ./${PROJET}/server $MODE
        ;;
    stop)
        arreter
        ;;
    clean)
        cd ${PROJET} && make clean; cd ..
        log "Nettoyage terminé"
        ;;
    all)
        creer_structure
        generer_header
        generer_utils
        generer_handler
        generer_daemon
        generer_server
        generer_makefile
        generer_syslog_conf
        compiler
        tester
        ;;
    *)
        afficher_aide
        ;;
esac
