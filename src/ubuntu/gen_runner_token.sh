token=$1
owner=$2
registration_token=$(curl -s -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $token" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/orgs/$owner/actions/runners/registration-token | jq -r '.token')
echo "$registration_token"