#!/bin/bash

# GitHub Token 作为脚本参数传入
token=$1

# 指定操作系统
os_filter=$2

# GitHub 仓库所有者和仓库名称
owner="RenGamesTeam"

# 获取所有指定操作系统的 Runner IDs
runner_ids=$(curl -s -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/orgs/$owner/actions/runners | jq -r --arg os_filter "$os_filter" ".runners[] | select(.os == \"$os_filter\") | .id")

if [ -z "$runner_ids" ]; then
  echo "No runners found for OS $os_filter."
  exit 0
fi

echo "Runner IDs with OS $os_filter: $runner_ids"

# 循环删除所有 Runner
for runid in $runner_ids; do
  echo "Deleting Runner ID: $runid"
  response=$(curl -s -o /dev/null -w "%{http_code}" -L \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/orgs/$owner/actions/runners/$runid)

  if [ "$response" -eq 204 ]; then
    echo "Runner ID $runid deleted successfully."
  else
    echo "Failed to delete Runner ID $runid. HTTP response code: $response"
  fi
done
