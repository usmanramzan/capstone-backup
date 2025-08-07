#!/bin/sh

set -eu  

# === FLAGS ===
TARGET_DIR=""
DO_INCREMENTAL=false
DO_REPORT=false

# === ARGUMENT PARSING ===
while getopts ":d:ir" opt; do
  case $opt in
    d) TARGET_DIR="$OPTARG" ;;
    i) DO_INCREMENTAL=true ;;
    r) DO_REPORT=true ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# === VALIDATION ===
if [ -z "$TARGET_DIR" ]; then
  echo "ERROR: Target directory (-d) is required."
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: Target directory '$TARGET_DIR' does not exist."
  exit 2
fi

# === CONFIGURATION ===
DATE=$(date +"%Y%m%d")
TIME=$(date +"%H:%M:%S")
TIMESTAMP=$(date +"%s")
BASE_DIR=/app
BACKUP_DIR="$BASE_DIR/backups/incremental-$DATE"
LOG_FILE="$BASE_DIR/logs/backup-$DATE.log"
REPORT_FILE="$BASE_DIR/reports/report-$DATE.txt"
ARCHIVE_FILE="$BACKUP_DIR/backup_$(basename "$TARGET_DIR")_$DATE.tar.gz"

# === ENV LOADING ===
if [ -f "$BASE_DIR/.env" ]; then
  export $(grep -v '^#' "$BASE_DIR/.env" | xargs)
fi

# === CHECK REQUIRED ENV VARS ===
: "${USERNAME_GITHUB:?USERNAME_GITHUB is not set in .env}"
: "${TOKEN_GITHUB:?TOKEN_GITHUB is not set in .env}"
: "${EMAIL_GIT:?EMAIL_GIT is not set in .env}"

REPO_NAME="capstone-backup"
API_URL="https://api.github.com/repos/$USERNAME_GITHUB/$REPO_NAME"
REPO_URL="https://$USERNAME_GITHUB:$TOKEN_GITHUB@github.com/$USERNAME_GITHUB/$REPO_NAME.git"

# === PREP ===
mkdir -p "$BACKUP_DIR" "$BASE_DIR/logs" "$BASE_DIR/reports"

# === LOG START ===
echo "$TIMESTAMP | Backup process started at $DATE $TIME"
{
  echo "--------------------------------------------------"
  echo "[${DATE} ${TIME}] Starting Backup"
  echo "--------------------------------------------------"
  echo "Target Directory : $TARGET_DIR"
  echo "Backup Destination: $ARCHIVE_FILE"
  echo ""
} >> "$LOG_FILE"

# === BACKUP ===
echo "$TIMESTAMP | Archiving $TARGET_DIR"
echo "[${DATE} ${TIME}] Archiving $TARGET_DIR..." >> "$LOG_FILE"
tar -czf "$ARCHIVE_FILE" -C "$(dirname "$TARGET_DIR")" "$(basename "$TARGET_DIR")" >> "$LOG_FILE" 2>&1
echo "$TIMESTAMP | Backup archive created successfully"
echo "[${DATE} ${TIME}] Backup completed." >> "$LOG_FILE"

# === REPORT (optional) ===
if $DO_REPORT; then
  echo "$TIMESTAMP | Generating backup report"
  {
    echo "--------------------------------------------------"
    echo "[${DATE} ${TIME}] Backup Report"
    echo "--------------------------------------------------"
    echo "Timestamp        : $DATE $TIME"
    echo "Backed Up Dir    : $TARGET_DIR"
    echo "Archive File     : $ARCHIVE_FILE"
    echo "Archive Size     : $(du -sh "$ARCHIVE_FILE" | cut -f1)"
    echo ""
  } >> "$REPORT_FILE"
fi

# === CHECK IF REPO EXISTS ===
echo "$TIMESTAMP | Checking if GitHub repository exists"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN_GITHUB" "$API_URL")

if [ "$HTTP_STATUS" -ne 200 ]; then
  echo "$TIMESTAMP | GitHub repo $REPO_NAME does not exist, creating new repository"
  curl -s -H "Authorization: token $TOKEN_GITHUB" \
       -d "{\"name\":\"$REPO_NAME\",\"description\":\"Automated backup repository\"}" \
       https://api.github.com/user/repos > /dev/null || {
         echo "$TIMESTAMP | ERROR: Failed to create repository, check GitHub token and permissions"
         exit 1
       }
  echo "$TIMESTAMP | Repository $REPO_NAME created successfully"
  

  cd "$BASE_DIR"
  git init
  git config user.name "BackupBot"
  git config user.email "$EMAIL_GIT"
  git remote add origin "$REPO_URL"
  
 
  if [ ! -f .gitignore ]; then
    cat > .gitignore << EOF
# Temporary files
*.tmp
*.temp

# OS files
.DS_Store
Thumbs.db

# IDE files
.vscode/
.idea/
EOF
  fi
  
  git add .
  git commit -m "Initial backup repository setup - $(date)"
  git branch -M main
  git push -u origin main
  echo "$TIMESTAMP | Repository initialized and first commit pushed"
  
else
  echo "$TIMESTAMP | Repository $REPO_NAME already exists"
  

  cd "$BASE_DIR"
  if [ ! -d ".git" ]; then
    echo "$TIMESTAMP | Initializing git repository in $BASE_DIR"
    git init
    git config user.name "BackupBot"
    git config user.email "$EMAIL_GIT"
    git remote add origin "$REPO_URL"
    git fetch origin
    git reset --hard origin/main 2>/dev/null || echo "$TIMESTAMP | No previous commits found, starting fresh"
  else
    echo "$TIMESTAMP | Git repository already initialized"
    git config user.name "BackupBot"
    git config user.email "$EMAIL_GIT"
    
 
    if ! git remote get-url origin >/dev/null 2>&1; then
      git remote add origin "$REPO_URL"
    else
      git remote set-url origin "$REPO_URL"
    fi
  fi
fi

# === PUSH CHANGES TO GITHUB ===
echo "$TIMESTAMP | Checking for changes to push to GitHub"
cd "$BASE_DIR"

# Add all changes
git add .

# Check if there are changes to commit
if git diff --staged --quiet; then
  echo "$TIMESTAMP | No changes detected, repository is up to date"
else
  echo "$TIMESTAMP | Changes detected, committing and pushing to GitHub"
  # Commit changes
  COMMIT_MSG="Backup update - $DATE $TIME"
  git commit -m "$COMMIT_MSG"
  
  # Push to GitHub
  git push origin main || {
    echo "$TIMESTAMP | Failed to push, attempting to pull and merge first"
    git pull origin main --allow-unrelated-histories || true
    git push origin main
  }
  
  echo "$TIMESTAMP | Changes pushed to GitHub successfully"
fi

# === CREATE TAG ===
echo "$TIMESTAMP | Creating backup tag"
TAG_NAME="backup-$DATE-$(echo $TIME | tr ':' '-')"
git tag -a "$TAG_NAME" -m "Backup taken on $DATE at $TIME" || echo "$TIMESTAMP | Warning: Tag may already exist"
git push origin "$TAG_NAME" || echo "$TIMESTAMP | Warning: Could not push tag (may already exist)"

echo "$TIMESTAMP | Backup process completed successfully"
echo "$TIMESTAMP | Archive created: $ARCHIVE_FILE"
echo "$TIMESTAMP | Log file: $LOG_FILE"
if $DO_REPORT; then
  echo "$TIMESTAMP | Report file: $REPORT_FILE"
fi
echo "$TIMESTAMP | GitHub repository: https://github.com/$USERNAME_GITHUB/$REPO_NAME"
