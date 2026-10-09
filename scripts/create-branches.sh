#!/usr/bin/env bash
# Crea branches en GitHub a partir de work items de Azure Boards.
#   Epic con tags de equipo -> feature/{team}/{epicId}-{slug}   (desde develop, una por equipo)
#   User Story              -> story/{team}/{id}-{slug}         (desde la feature de su Epic)
#   Bug                     -> bugfix/{team}/{id}-{slug}        (desde la feature de su Epic)
# Es idempotente: si la branch ya existe no hace nada.
#
# Variables de entorno requeridas:
#   WORK_ITEM_ID, SYSTEM_ACCESSTOKEN, SYSTEM_COLLECTIONURI, SYSTEM_TEAMPROJECTID,
#   GITHUB_TOKEN, GITHUB_REPO (owner/repo), TEAM_TAGS (lista separada por comas)
# Opcionales: BASE_BRANCH (default develop), STORY_TYPES, BUG_TYPES
set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-develop}"
STORY_TYPES="${STORY_TYPES:-User Story,Product Backlog Item}"
BUG_TYPES="${BUG_TYPES:-Bug}"
ADO_API="${SYSTEM_COLLECTIONURI%/}/${SYSTEM_TEAMPROJECTID}/_apis/wit/workitems"
GH_API="https://api.github.com/repos/${GITHUB_REPO}"

if [[ -z "${WORK_ITEM_ID:-}" ]]; then
  echo "Sin WORK_ITEM_ID (ejecución manual), nada que hacer."
  exit 0
fi

ado() { curl -sfS -H "Authorization: Bearer ${SYSTEM_ACCESSTOKEN}" "$1"; }
gh_api() {
  curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# "Login con Google (OAuth)!" -> "login-con-google-oauth"
slugify() {
  printf '%s' "$1" \
    | sed -E 's/(Á|á|À|à|Ä|ä|Â|â)/a/g; s/(É|é|È|è|Ë|ë|Ê|ê)/e/g; s/(Í|í|Ì|ì|Ï|ï|Î|î)/i/g;
              s/(Ó|ó|Ò|ò|Ö|ö|Ô|ô)/o/g; s/(Ú|ú|Ù|ù|Ü|ü|Û|û)/u/g; s/(Ñ|ñ)/n/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//'
}

in_list() { [[ ",$2," == *",$1,"* ]]; }

get_wi() { ado "${ADO_API}/$1?api-version=7.1"; }

# Tags del work item que corresponden a equipos válidos (uno por línea, en minúscula)
teams_of() {
  jq -r --arg valid "$TEAM_TAGS" '
    ($valid | ascii_downcase | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $v
    | (.fields["System.Tags"] // "") | ascii_downcase | split(";")
    | map(gsub("^\\s+|\\s+$"; "")) | map(select(. as $t | $v | index($t)))[]' <<<"$1"
}

# Sube por System.Parent hasta encontrar el Epic
find_epic() {
  local wi=$1 parent
  while true; do
    [[ "$(jq -r '.fields["System.WorkItemType"]' <<<"$wi")" == "Epic" ]] && { echo "$wi"; return 0; }
    parent=$(jq -r '.fields["System.Parent"] // empty' <<<"$wi")
    [[ -z "$parent" ]] && return 1
    wi=$(get_wi "$parent")
  done
}

branch_sha() { gh_api "${GH_API}/git/ref/heads/$1" | jq -r '.object.sha // empty'; }

# Primera branch cuyo nombre empieza con el prefijo (así no depende del título actual)
find_branch() {
  gh_api "${GH_API}/git/matching-refs/heads/$1" | jq -r '.[0].ref // empty' | sed 's#^refs/heads/##'
}

create_branch() {
  local new=$1 base=$2 sha resp
  sha=$(branch_sha "$base")
  if [[ -z "$sha" ]]; then
    echo "##vso[task.logissue type=error]No existe la branch base '$base'"
    exit 1
  fi
  resp=$(gh_api -X POST "${GH_API}/git/refs" -d "{\"ref\":\"refs/heads/${new}\",\"sha\":\"${sha}\"}")
  if jq -e '.ref' <<<"$resp" >/dev/null 2>&1; then
    echo "Creada: $new (desde $base)"
  elif grep -q "Reference already exists" <<<"$resp"; then
    echo "Ya existe: $new"
  else
    echo "##vso[task.logissue type=error]Error creando $new: $resp"
    exit 1
  fi
}

# Agrega al work item un Hyperlink a la branch en GitHub (si todavía no lo tiene)
link_branch() {
  local wid=$1 branch=$2 url current body resp
  url="https://github.com/${GITHUB_REPO}/tree/${branch}"
  current=$(ado "${ADO_API}/${wid}?\$expand=relations&api-version=7.1")
  if jq -e --arg u "$url" 'any((.relations // [])[]; .url == $u)' <<<"$current" >/dev/null; then
    echo "Link ya presente en #$wid: $url"
    return
  fi
  body=$(jq -nc --arg u "$url" --arg c "Branch ${branch}" \
    '[{op: "add", path: "/relations/-", value: {rel: "Hyperlink", url: $u, attributes: {comment: $c}}}]')
  resp=$(curl -sS -X PATCH -H "Authorization: Bearer ${SYSTEM_ACCESSTOKEN}" \
    -H "Content-Type: application/json-patch+json" "${ADO_API}/${wid}?api-version=7.1" -d "$body")
  if jq -e '.id' <<<"$resp" >/dev/null 2>&1; then
    echo "Link agregado en #$wid: $url"
  else
    echo "##vso[task.logissue type=warning]No se pudo linkear #$wid (¿permiso 'Edit work items' para el Build Service?): $resp"
  fi
}

# Devuelve (stdout) el nombre de la feature branch del equipo para el Epic, creándola si falta
ensure_feature() {
  local team=$1 epic=$2 id title existing name
  id=$(jq -r '.id' <<<"$epic")
  title=$(jq -r '.fields["System.Title"]' <<<"$epic")
  name=$(find_branch "feature/${team}/${id}-")
  if [[ -n "$name" ]]; then
    echo "Ya existe: $name" >&2
  else
    name="feature/${team}/${id}-$(slugify "$title")"
    create_branch "$name" "$BASE_BRANCH" >&2
  fi
  link_branch "$id" "$name" >&2
  echo "$name"
}

wi=$(get_wi "$WORK_ITEM_ID")
type=$(jq -r '.fields["System.WorkItemType"]' <<<"$wi")
id=$(jq -r '.id' <<<"$wi")
title=$(jq -r '.fields["System.Title"]' <<<"$wi")
echo "Work item #$id ($type): $title"

if [[ "$type" == "Epic" ]]; then
  mapfile -t teams < <(teams_of "$wi")
  if [[ ${#teams[@]} -eq 0 ]]; then
    echo "El Epic no tiene tags de equipo, nada que hacer."
    exit 0
  fi
  for team in "${teams[@]}"; do ensure_feature "$team" "$wi" >/dev/null; done

elif in_list "$type" "$STORY_TYPES" || in_list "$type" "$BUG_TYPES"; then
  prefix=story
  in_list "$type" "$BUG_TYPES" && prefix=bugfix

  if ! epic=$(find_epic "$wi"); then
    echo "No tiene un Epic como ancestro, nada que hacer."
    exit 0
  fi

  # Equipo: el tag del propio work item; si no tiene, hereda el del Epic cuando es uno solo
  mapfile -t teams < <(teams_of "$wi")
  if [[ ${#teams[@]} -eq 0 ]]; then
    mapfile -t epic_teams < <(teams_of "$epic")
    [[ ${#epic_teams[@]} -eq 1 ]] && teams=("${epic_teams[@]}")
  fi
  if [[ ${#teams[@]} -eq 0 ]]; then
    echo "##vso[task.logissue type=warning]#$id no tiene tag de equipo y el Epic tiene 0 o varios equipos; agregale un tag de equipo."
    exit 0
  fi

  for team in "${teams[@]}"; do
    feature=$(ensure_feature "$team" "$epic")
    branch=$(find_branch "${prefix}/${team}/${id}-")
    if [[ -n "$branch" ]]; then
      echo "Ya existe: $branch"
    else
      branch="${prefix}/${team}/${id}-$(slugify "$title")"
      create_branch "$branch" "$feature"
    fi
    link_branch "$id" "$branch"
  done

else
  echo "Tipo '$type' ignorado."
fi
