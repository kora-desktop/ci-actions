#!/usr/bin/env bash
# Write a git config that fetches each org's repositories over HTTPS with that org's app token,
# and points every old playtron-os URL at wherever the repository lives now.
# macOS runners ship bash 3.2, so this avoids associative arrays and other bash 4 features.
set -euo pipefail

: "${TOKEN_KORA_DESKTOP:?}" "${TOKEN_HUMAIN_OS:?}" "${TOKEN_PLAYTRON_OS:?}"
# A name in several orgs resolves to the original over a fork, then to the first org listed here.
orgs="kora-desktop playtron-os humain-os"

# Sets T to the org's token without a subshell.
token() {
  case $1 in
    kora-desktop) T=$TOKEN_KORA_DESKTOP ;;
    humain-os) T=$TOKEN_HUMAIN_OS ;;
    playtron-os) T=$TOKEN_PLAYTRON_OS ;;
  esac
}

umask 077
dir=${RUNNER_TEMP:?}/git-auth
mkdir -p "$dir"
cfg=$dir/gitconfig
: >"$cfg"
: >"$dir/repos.tsv"

rank=0
for org in $orgs; do
  token "$org"
  page=1
  while :; do
    rows=$(curl -fsS -H "Authorization: Bearer $T" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/installation/repositories?per_page=100&page=$page" |
      jq -r --arg org "$org" --argjson rank "$rank" \
        '.repositories[] | "\(.name)\t\($org)\t\(if .fork then 1 else 0 end)\t\($rank)\t\(if .private then 1 else 0 end)"')
    [[ -n $rows ]] || break
    printf '%s\n' "$rows" >>"$dir/repos.tsv"
    page=$((page + 1))
  done
  rank=$((rank + 1))
done

# "name<TAB>org", one line per repository name.
sort -t "$(printf '\t')" -k1,1 -k3,3n -k4,4n "$dir/repos.tsv" |
  awk -F '\t' '!seen[$1]++ { print $1 "\t" $2 }' >"$dir/homes.tsv"

# rule <org> <path in org> <path the URL uses>; git picks the longest matching prefix,
# so every repository gets its own rule and similar names never capture each other.
# Only SSH-style URLs are rewritten: the job's own https remote keeps the workflow's token for pushes.
rule() {
  token "$1"
  printf '[url "https://x-access-token:%s@github.com/%s/%s"]\n' "$T" "$1" "$2" >>"$cfg"
  printf '\tinsteadOf = %s\n' "ssh://git@github.com/$3" "ssh://git@github.com:22/$3" "git@github.com:$3" >>"$cfg"
}

for org in $orgs; do
  rule "$org" "" "$org/"
done
while IFS="$(printf '\t')" read -r name org; do
  rule "$org" "$name" "playtron-os/$name"
done <"$dir/homes.tsv"
# Old names whose repository now lives under its new name. The list is internal, so it is read
# at run time with the kora-desktop token; without it, only current names are routed.
token kora-desktop
curl -fsS -H "Authorization: Bearer $T" -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/kora-desktop/ci-config/contents/git-auth/renames.tsv" >"$dir/renames.tsv" 2>/dev/null ||
  : >"$dir/renames.tsv"
awk -F '\t' 'NR == FNR { home[$1] = $2; next } ($2 in home) && !($1 in home) { print $1 "\t" $2 "\t" home[$2] }' \
  "$dir/homes.tsv" "$dir/renames.tsv" |
  while IFS="$(printf '\t')" read -r old new org; do
    rule "$org" "$new" "playtron-os/$old"
  done

git config --global --add include.path "$cfg"
echo "GIT_AUTH_CONFIG=$cfg" >>"$GITHUB_ENV"
echo "config=$cfg" >>"$GITHUB_OUTPUT"
echo "git-auth: $(wc -l <"$dir/homes.tsv" | tr -d ' ') repositories across 3 orgs, $(grep -c . "$dir/renames.tsv" || true) old names"
