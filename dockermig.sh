#!/bin/bash

LOG_FILE="docker_transfer.log"
exec > >(tee -a $LOG_FILE) 2>&1

function print_step() {
  echo "=========================="
  echo "$1"
  echo "=========================="
}

# Vérification des prérequis
print_step "Vérification des prérequis"
command -v docker >/dev/null 2>&1 || { echo "Docker n'est pas installé. Abandon."; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "SSH n'est pas installé. Abandon."; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "SCP n'est pas installé. Abandon."; exit 1; }

# Récupérer la liste de tous les conteneurs Docker
print_step "Liste des conteneurs disponibles sur cet hôte"
docker ps --format "table {{.Names}}\t{{.Image}}"

# Demander l'hôte distant
read -p "Entrez l'utilisateur et l'hôte distant (ex. user@remotehost) : " REMOTE_USER_HOST

# Parcourir tous les conteneurs actifs
docker ps --format "{{.Names}}" | while read CONTAINER_NAME; do
  print_step "Traitement du conteneur : $CONTAINER_NAME"

  # Trouver l'image associée au conteneur
  IMAGE_NAME=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME")
  if [ -z "$IMAGE_NAME" ]; then
    echo "Erreur : Impossible de trouver l'image associée au conteneur $CONTAINER_NAME."
    continue
  fi

  # Trouver les volumes associés au conteneur
  VOLUMES=$(docker inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$CONTAINER_NAME")

  # Vérifier si l'image existe sur l'hôte distant ou la télécharger
  print_step "Vérification ou téléchargement de l'image sur l'hôte distant"
  ssh "$REMOTE_USER_HOST" "if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qw $IMAGE_NAME; then docker pull $IMAGE_NAME; fi"
  if [ $? -ne 0 ]; then
    echo "Erreur : Échec du téléchargement de l'image $IMAGE_NAME sur l'hôte distant."
    continue
  fi
  echo "✔ Image disponible sur l'hôte distant."

  # Transférer les volumes associés
  print_step "Transfert des volumes associés"
  for VOLUME in $VOLUMES; do
    SRC=$(echo $VOLUME | cut -d':' -f1)
    DEST=$(echo $VOLUME | cut -d':' -f2)

    # Vérifier l'existence du volume local
    if [ ! -d "$SRC" ]; then
      echo "Erreur : Le volume source $SRC n'existe pas localement. Passage au suivant."
      continue
    fi

    VOLUME_ARCHIVE="${CONTAINER_NAME}_$(basename $SRC).tar.gz"
    echo "Archivage du volume $SRC..."
    tar -czf "$VOLUME_ARCHIVE" -C "$SRC" .
    echo "Transfert du volume $SRC vers $REMOTE_USER_HOST:$DEST..."
    scp "$VOLUME_ARCHIVE" "$REMOTE_USER_HOST:/tmp/$VOLUME_ARCHIVE"
    if [ $? -ne 0 ]; then
      echo "Erreur : Échec du transfert du volume $SRC pour le conteneur $CONTAINER_NAME."
      rm -f "$VOLUME_ARCHIVE"
      continue
    fi

    echo "Extraction du volume sur l'hôte distant..."
    ssh "$REMOTE_USER_HOST" "mkdir -p $DEST && tar -xzf /tmp/$VOLUME_ARCHIVE -C $DEST && rm -f /tmp/$VOLUME_ARCHIVE"
    if [ $? -ne 0 ]; then
      echo "Erreur : Échec de l'extraction du volume sur l'hôte distant."
      rm -f "$VOLUME_ARCHIVE"
      continue
    fi
    rm -f "$VOLUME_ARCHIVE"
  done
  echo "✔ Volumes transférés avec succès."

  # Recréer le conteneur avec les mêmes configurations
  print_step "Recréation du conteneur sur l'hôte distant"
  ssh "$REMOTE_USER_HOST" "docker run -d --name $CONTAINER_NAME $(echo $VOLUMES | sed -E 's/([^ ]+):([^ ]+)/-v \1:\2/g') $IMAGE_NAME"
  if [ $? -ne 0 ]; then
    echo "Erreur : Échec de la recréation du conteneur sur l'hôte distant pour $CONTAINER_NAME."
    continue
  fi
  echo "✔ Conteneur recréé avec succès."
done

# Récapitulatif final
print_step "Tous les conteneurs ont été traités"
echo "Transfert, importation et démarrage de tous les conteneurs terminés."
