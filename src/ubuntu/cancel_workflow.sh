#!/bin/bash

# GitHub Personal Access Token (请替换为你的令牌)
token=$1
run_id=$2

# GitHub 仓库所有者和仓库名称
owner="RenGamesTeam"
repo="PublicRunners"

# 取消指定的工作流运行
  curl -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    https://api.github.com/repos/$owner/$repo/actions/runs/$run_id/cancel
