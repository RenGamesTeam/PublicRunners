#!/bin/bash

token=$1

# 流程名称
workflow_name=$2

# GitHub 仓库所有者和仓库名称
owner="RenGamesTeam"
repo="PublicRunners"

# 获取流程对应ID
workflow_id=$(curl -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $token" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$owner/$repo/actions/workflows | jq -r ".workflows[] | select(.name == \"$workflow_name\") | .id")

# 启动
curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $token" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$owner/$repo/actions/workflows/$workflow_id/dispatches \
  -d '{"ref":"main"}'