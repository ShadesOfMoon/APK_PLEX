#!/bin/bash

# Script interactif pour transférer un conteneur Docker entre deux hôtes avec étapes détaillées
LOG_FILE="docker_transfer.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Fonction pour afficher les étapes clairement
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

# Liste des conteneurs disponibles
print_step "Liste des conteneurs disponibles sur cet hôte"
docker ps --format "table {{.Names}}\t{{.Image}}"

# Demander à l'utilisateur de choisir un conteneur
read -p "Entrez le nom du conteneur à transférer : " CONTAINER_NAME

# Vérifier si le conteneur existe
if ! docker ps --format "{{.Names}}" | grep -qw "$CONTAINER_NAME"; then
  echo "Erreur : Le conteneur $CONTAINER_NAME n'existe pas."
  exit 1
fi

# Trouver l'image associée au conteneur
IMAGE_NAME=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME")
if [ -z "$IMAGE_NAME" ]; then
  echo "Erreur : Impossible de trouver l'image associée au conteneur $CONTAINER_NAME."
  exit 1
fi

# Trouver les volumes associés au conteneur
VOLUMES=$(docker inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$CONTAINER_NAME")

# Demander l'hôte distant et le chemin de destination
read -p "Entrez l'utilisateur et l'hôte distant (ex. user@remotehost) : " REMOTE_USER_HOST
read -p "Entrez le chemin distant où transférer l'image (ex. /tmp) : " REMOTE_PATH

# Exporter l'image Docker
EXPORT_FILE="${IMAGE_NAME//[:\\/]/_}.tar"
print_step "Exportation de l'image Docker"
docker save -o "$EXPORT_FILE" "$IMAGE_NAME"
if [ $? -ne 0 ]; then
  echo "Erreur : Échec de l'exportation de l'image Docker."
  exit 1
fi
echo "✔ Image exportée avec succès : $EXPORT_FILE"

# Transférer l'image à l'hôte distant
print_step "Transfert de l'image vers l'hôte distant"
scp "$EXPORT_FILE" "$REMOTE_USER_HOST:$REMOTE_PATH"
if [ $? -ne 0 ]; then
  echo "Erreur : Échec du transfert de l'image Docker."
  rm -f "$EXPORT_FILE"
  exit 1
fi
echo "✔ Image transférée avec succès."

# Transférer les volumes associés
print_step "Transfert des volumes associés"
for VOLUME in $VOLUMES; do
  SRC=$(echo $VOLUME | cut -d':' -f1)
  DEST=$(echo $VOLUME | cut -d':' -f2)
  VOLUME_ARCHIVE="$(basename $SRC).tar.gz"
  echo "Archivage du volume $SRC..."
  tar -czf "$VOLUME_ARCHIVE" -C "$SRC" .
  echo "Transfert du volume $SRC vers $REMOTE_USER_HOST:$REMOTE_PATH/$VOLUME_ARCHIVE..."
  scp "$VOLUME_ARCHIVE" "$REMOTE_USER_HOST:$REMOTE_PATH"
  if [ $? -ne 0 ]; then
    echo "Erreur : Échec du transfert du volume $SRC."
    rm -f "$VOLUME_ARCHIVE"
    exit 1
  fi
  echo "Extraction du volume sur l'hôte distant..."
  ssh "$REMOTE_USER_HOST" "mkdir -p $DEST && tar -xzf $REMOTE_PATH/$VOLUME_ARCHIVE -C $DEST"
  if [ $? -ne 0 ]; then
    echo "Erreur : Échec de l'extraction du volume sur l'hôte distant."
    rm -f "$VOLUME_ARCHIVE"
    exit 1
  fi
  rm -f "$VOLUME_ARCHIVE"
done
echo "✔ Volumes transférés avec succès."

# Charger l'image sur l'hôte distant
print_step "Chargement de l'image sur l'hôte distant"
REMOTE_COMMAND="docker load -i $REMOTE_PATH/$(basename $EXPORT_FILE) && docker images"
ssh "$REMOTE_USER_HOST" "$REMOTE_COMMAND"
if [ $? -ne 0 ]; then
  echo "Erreur : Échec du chargement de l'image sur l'hôte distant."
  rm -f "$EXPORT_FILE"
  exit 1
fi
echo "✔ Image chargée avec succès sur l'hôte distant."

# Démarrage du conteneur sur l'hôte distant
print_step "Démarrage du conteneur sur l'hôte distant"
CONTAINER_RUN_COMMAND="docker run -d --name $CONTAINER_NAME $(echo $VOLUMES | sed -E 's/([^ ]+):([^ ]+)/-v \\1:\\2/g') $IMAGE_NAME"
ssh "$REMOTE_USER_HOST" "$CONTAINER_RUN_COMMAND"
if [ $? -ne 0 ]; then
  echo "Erreur : Échec du démarrage du conteneur sur l'hôte distant."
  exit 1
fi
echo "✔ Conteneur démarré avec succès."

# Nettoyage local
print_step "Nettoyage local"
rm -f "$EXPORT_FILE"
echo "✔ Nettoyage terminé."

# Récapitulatif final
print_step "Récapitulatif final"
echo "Transfert, importation et démarrage du conteneur réussis !"
echo "  - Conteneur : $CONTAINER_NAME"
echo "  - Image : $IMAGE_NAME"
echo "  - Volumes : $(echo $VOLUMES | tr ' ' '\\n')"
echo "  - Hôte distant : $REMOTE_USER_HOST"
